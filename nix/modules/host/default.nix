{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.seter.host;
  inherit (lib)
    attrNames
    concatMap
    mapAttrs
    mapAttrs'
    mapAttrsToList
    mkEnableOption
    mkIf
    nameValuePair
    mkOption
    types
    unique
    ;

  workspaceType = types.submodule (import ./workspace.nix);
  defaultPackage = pkgs.callPackage ../../package.nix { };
  lifecycleLockDirectory = "/run/lock/seter";
  workspaces = mapAttrsToList (name: workspace: workspace // { inherit name; }) cfg.workspaces;

  valuesFor = select: map select workspaces;
  hasUniqueValues = values: builtins.length values == builtins.length (unique values);
  nonBlank = value: builtins.match ".*[^[:space:]].*" value != null;

  parseIpv4 =
    address:
    let
      rawParts = lib.splitString "." address;
      parsePart =
        part: if builtins.match "(0|[1-9][0-9]{0,2})" part == null then null else lib.toInt part;
      parts = map parsePart rawParts;
      valid = builtins.length parts == 4 && lib.all (part: part != null && part <= 255) parts;
    in
    if valid then lib.foldl' (value: part: value * 256 + part) 0 parts else null;

  pow2 = exponent: if exponent == 0 then 1 else 2 * pow2 (exponent - 1);
  subnetParts = lib.splitString "/" cfg.subnet;
  subnetAddress = parseIpv4 (builtins.elemAt subnetParts 0);
  subnetPrefix = lib.toInt (builtins.elemAt subnetParts 1);
  subnetBlockSize = pow2 (32 - subnetPrefix);
  subnetNetwork =
    if subnetAddress == null then
      null
    else
      builtins.div subnetAddress subnetBlockSize * subnetBlockSize;
  subnetBroadcast = if subnetNetwork == null then null else subnetNetwork + subnetBlockSize - 1;
  gatewayAddress = parseIpv4 cfg.gateway;
  addressInSubnet =
    address:
    let
      parsedAddress = parseIpv4 address;
    in
    parsedAddress != null
    && subnetAddress != null
    && builtins.div parsedAddress subnetBlockSize == builtins.div subnetAddress subnetBlockSize;

  addressIsUsable =
    address:
    let
      parsedAddress = parseIpv4 address;
    in
    parsedAddress != null
    && addressInSubnet address
    && parsedAddress != subnetNetwork
    && parsedAddress != subnetBroadcast;

  workspaceSecrets = workspace: builtins.attrValues workspace.secrets;
  normalizeHosts = map lib.toLower;
  allowedSecretHosts =
    workspace: normalizeHosts (workspace.egress.httpHosts ++ workspace.egress.passthroughHosts);
  secretHosts =
    workspace: normalizeHosts (concatMap (secret: secret.hosts) (workspaceSecrets workspace));

  lifecycleRegistry = {
    version = 2;
    workspaces = mapAttrs (name: workspace: {
      inherit (workspace) hostname;
      inherit (workspace)
        runner
        network
        resources
        ssh
        storage
        ;
    }) cfg.workspaces;
  };

  registryFile = pkgs.writeText "seter-workspaces.json" (builtins.toJSON lifecycleRegistry);

  workspaceRuntime = mapAttrs (
    name: workspace:
    let
      suffix = builtins.substring 0 8 (builtins.hashString "sha256" name);
      account = "seter-${builtins.substring 0 12 name}-${suffix}";
    in
    {
      inherit account workspace;
      lifecycleLock = "${lifecycleLockDirectory}/${name}.lock";
      runtimeDirectory = "seter/${name}";
      socket = "/run/seter/${name}/virtiofs-ro-store.sock";
      stateDirectory = "/var/lib/seter/workspaces/${name}";
    }
  ) cfg.workspaces;

  lifecycleSudoCommands = concatMap (
    name:
    map
      (operation: {
        command = "${lib.getExe cfg.package} ${operation} ${name}";
        options = [ "NOPASSWD" ];
      })
      [
        "__start"
        "__stop"
      ]
  ) (attrNames cfg.workspaces);

  tapServices = mapAttrs' (
    name: runtime:
    let
      inherit (runtime) account workspace;
      tap = workspace.network.tap;
      tapUp = pkgs.writeShellScript "seter-tap-${name}-up" ''
        set -eu

        if ${pkgs.iproute2}/bin/ip link show dev ${lib.escapeShellArg tap} >/dev/null 2>&1; then
          echo "refusing to replace existing interface ${tap}" >&2
          exit 1
        fi

        for attempt in $(${pkgs.coreutils}/bin/seq 1 100); do
          test -e /sys/class/net/${lib.escapeShellArg cfg.bridge} && break
          ${pkgs.coreutils}/bin/sleep 0.1
        done
        if ! test -e /sys/class/net/${lib.escapeShellArg cfg.bridge}; then
          echo "Seter bridge ${cfg.bridge} did not appear" >&2
          exit 1
        fi

        cleanup() {
          ${pkgs.iproute2}/bin/ip link delete dev ${lib.escapeShellArg tap} 2>/dev/null || true
        }
        trap cleanup EXIT

        ${pkgs.iproute2}/bin/ip tuntap add \
          name ${lib.escapeShellArg tap} \
          mode tap \
          user ${lib.escapeShellArg account} \
          group ${lib.escapeShellArg account} \
          vnet_hdr multi_queue
        ${pkgs.iproute2}/bin/ip link set dev ${lib.escapeShellArg tap} master ${lib.escapeShellArg cfg.bridge}
        ${pkgs.iproute2}/bin/bridge link set dev ${lib.escapeShellArg tap} isolated on
        ${pkgs.iproute2}/bin/ip link set dev ${lib.escapeShellArg tap} up

        trap - EXIT
      '';
      tapDown = pkgs.writeShellScript "seter-tap-${name}-down" ''
        set -eu
        if ${pkgs.iproute2}/bin/ip link show dev ${lib.escapeShellArg tap} >/dev/null 2>&1; then
          ${pkgs.iproute2}/bin/ip link delete dev ${lib.escapeShellArg tap}
        fi
      '';
    in
    nameValuePair "seter-tap-${name}" {
      description = "Seter TAP interface for workspace ${name}";
      after = [
        "nftables.service"
        "seter-bridge.service"
        "seter-dns-${name}.service"
      ];
      requires = [
        "nftables.service"
        "seter-bridge.service"
        "seter-dns-${name}.service"
      ];
      partOf = [ "seter-runtime-${name}.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = tapUp;
        ExecStop = tapDown;
      };
    }
  ) workspaceRuntime;

  virtiofsdServices = mapAttrs' (
    name: runtime:
    let
      inherit (runtime) account socket;
      runVirtiofsd = pkgs.writeShellScript "seter-virtiofsd-${name}" ''
        set -eu
        rm -f ${lib.escapeShellArg socket}
        ${lib.getExe pkgs.virtiofsd} \
          --socket-path=${lib.escapeShellArg socket} \
          --socket-group=${lib.escapeShellArg account} \
          --shared-dir=/nix/store \
          --readonly \
          --posix-acl=always \
          --cache=auto \
          --inode-file-handles=prefer &
        virtiofsd_pid=$!

        shutdown() {
          trap - INT TERM
          kill -TERM "$virtiofsd_pid" 2>/dev/null || true
          wait "$virtiofsd_pid" 2>/dev/null || true
          exit 0
        }
        trap shutdown INT TERM
        wait "$virtiofsd_pid"
      '';
      waitForSocket = pkgs.writeShellScript "seter-virtiofsd-${name}-ready" ''
        set -eu
        for attempt in $(${pkgs.coreutils}/bin/seq 1 100); do
          test -S ${lib.escapeShellArg socket} && exit 0
          ${pkgs.coreutils}/bin/sleep 0.05
        done
        echo "VirtioFS socket ${socket} did not become ready" >&2
        exit 1
      '';
    in
    nameValuePair "seter-virtiofsd-${name}" {
      description = "Read-only Nix store VirtioFS daemon for workspace ${name}";
      after = [ "seter-tap-${name}.service" ];
      requires = [ "seter-tap-${name}.service" ];
      bindsTo = [ "seter-tap-${name}.service" ];
      partOf = [ "seter-runtime-${name}.target" ];
      serviceConfig = {
        Type = "exec";
        User = account;
        Group = account;
        RuntimeDirectory = runtime.runtimeDirectory;
        RuntimeDirectoryMode = "0750";
        ExecStart = runVirtiofsd;
        ExecStartPost = waitForSocket;
        TimeoutStopSec = "10s";
        Restart = "on-failure";
        RestartSec = "1s";
        LimitNOFILE = 1048576;
        UMask = "0007";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      };
    }
  ) workspaceRuntime;

  runtimeTargets = mapAttrs' (
    name: _:
    nameValuePair "seter-runtime-${name}" {
      description = "Host runtime plumbing for Seter workspace ${name}";
      requires = [ "seter-virtiofsd-${name}.service" ];
      after = [ "seter-virtiofsd-${name}.service" ];
      # Stopping either half of the lifecycle tears down the other. The VM
      # service also has PartOf= on this target so operators may still stop
      # the plumbing target directly.
      partOf = [ "seter-vm-${name}.service" ];
    }
  ) workspaceRuntime;

  vmServices = mapAttrs' (
    name: runtime:
    let
      inherit (runtime) account lifecycleLock stateDirectory;
      workspace = runtime.workspace;
      runVm = pkgs.writeShellScript "seter-vm-${name}-run" ''
        set -eu
        exec {lifecycle_lock}<${lib.escapeShellArg lifecycleLock}
        ${pkgs.util-linux}/bin/flock --exclusive "$lifecycle_lock"
        runner=$(${pkgs.coreutils}/bin/readlink -f ${lib.escapeShellArg "${stateDirectory}/current"})
        test -x "$runner/bin/microvm-run"
        test -x "$runner/bin/microvm-shutdown"
        ${pkgs.coreutils}/bin/ln -sTf "$runner" ${lib.escapeShellArg "${stateDirectory}/booted"}
        exec ${lib.escapeShellArg "${stateDirectory}/booted/bin/microvm-run"}
      '';
      removeBooted = pkgs.writeShellScript "seter-vm-${name}-cleanup" ''
        ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg "${stateDirectory}/booted"}
      '';
    in
    nameValuePair "seter-vm-${name}" {
      description = "Seter microVM for workspace ${name}";
      requires = [ "seter-runtime-${name}.target" ];
      after = [ "seter-runtime-${name}.target" ];
      partOf = [ "seter-runtime-${name}.target" ];
      unitConfig.ConditionPathExists = "${stateDirectory}/current/bin/microvm-run";
      serviceConfig = {
        Type = "simple";
        User = account;
        Group = account;
        WorkingDirectory = stateDirectory;
        ExecStart = runVm;
        ExecStop = "${stateDirectory}/booted/bin/microvm-shutdown";
        ExecStopPost = removeBooted;
        TimeoutStopSec = "30s";
        KillMode = "mixed";
        Restart = "no";
        MemoryMax = workspace.resources.memoryMiB * 1024 * 1024;
        CPUQuota = "${toString workspace.resources.cpuQuotaPercent}%";
        LimitNOFILE = 1048576;
        LimitMEMLOCK = "infinity";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ stateDirectory ];
        DevicePolicy = "closed";
        DeviceAllow = [
          "/dev/kvm rw"
          "/dev/net/tun rw"
          "/dev/vhost-net rw"
          "/dev/vhost-vsock rw"
        ];
      };
    }
  ) workspaceRuntime;

  bridgeUp = pkgs.writeShellScript "seter-bridge-up" ''
    set -eu

    created=false
    cleanup() {
      if test "$created" = true; then
        ${pkgs.iproute2}/bin/ip link delete dev ${lib.escapeShellArg cfg.bridge} 2>/dev/null || true
      fi
    }
    trap cleanup EXIT

    if test -e /sys/class/net/${lib.escapeShellArg cfg.bridge}; then
      echo "refusing to replace existing interface ${cfg.bridge}" >&2
      exit 1
    fi

    ${pkgs.iproute2}/bin/ip link add name ${lib.escapeShellArg cfg.bridge} type bridge
    created=true

    ${pkgs.iproute2}/bin/ip address replace \
      ${lib.escapeShellArg "${cfg.gateway}/${toString subnetPrefix}"} \
      dev ${lib.escapeShellArg cfg.bridge}
    ${pkgs.iproute2}/bin/ip link set dev ${lib.escapeShellArg cfg.bridge} up

    trap - EXIT
  '';

  bridgeDown = pkgs.writeShellScript "seter-bridge-down" ''
    set -eu
    if test -e /sys/class/net/${lib.escapeShellArg cfg.bridge}; then
      ${pkgs.iproute2}/bin/ip link delete dev ${lib.escapeShellArg cfg.bridge}
    fi
  '';
in
{
  imports = [
    ./dns.nix
    ./network-policy.nix
  ];

  options.seter.host = {
    enable = mkEnableOption "the Seter micro-VM host";

    bridge = mkOption {
      type = types.strMatching "[a-zA-Z0-9_.-]{1,15}";
      default = "seter0";
      description = "Network bridge used by project VMs.";
    };

    subnet = mkOption {
      type = types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])";
      default = "10.100.0.0/24";
      description = "IPv4 subnet assigned to project VMs.";
    };

    gateway = mkOption {
      type = types.str;
      default = "10.100.0.1";
      description = "IPv4 address assigned to the Seter bridge and used as the guest gateway.";
    };

    workspaces = mkOption {
      type = types.attrsOf workspaceType;
      default = { };
      description = "Typed workspace registry used by the host and Seter CLI.";
    };

    package = mkOption {
      type = types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "the Seter package from this module's source";
      description = "Seter CLI package installed on the host and authorized for lifecycle helpers.";
    };

    operatorGroup = mkOption {
      type = types.strMatching "[a-z_][a-z0-9_-]*";
      default = "seter-operators";
      description = "Host group allowed to start and stop registered Seter workspaces without a sudo password.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (name: builtins.match "[a-z0-9][a-z0-9-]{0,62}" name != null) (
          attrNames cfg.workspaces
        );
        message = "seter.host.workspaces names must contain only lower-case letters, digits, and hyphens";
      }
      {
        assertion = subnetAddress != null;
        message = "seter.host.subnet must start with a valid IPv4 address";
      }
      {
        assertion = subnetPrefix <= 30;
        message = "seter.host.subnet must leave room for a gateway and at least one workspace";
      }
      {
        assertion = gatewayAddress != null && addressIsUsable cfg.gateway;
        message = "seter.host.gateway must be a usable IPv4 address in seter.host.subnet";
      }
      {
        assertion = lib.all (workspace: parseIpv4 workspace.network.address != null) workspaces;
        message = "seter.host.workspaces network addresses must be valid IPv4 addresses";
      }
      {
        assertion = lib.all (workspace: addressIsUsable workspace.network.address) workspaces;
        message = "seter.host.workspaces network addresses must be usable addresses in seter.host.subnet";
      }
      {
        assertion = lib.all (workspace: parseIpv4 workspace.network.address != gatewayAddress) workspaces;
        message = "seter.host.workspaces network addresses must not reuse seter.host.gateway";
      }
      {
        assertion = hasUniqueValues (valuesFor (workspace: parseIpv4 workspace.network.address));
        message = "seter.host.workspaces must assign a unique IPv4 address to every workspace";
      }
      {
        assertion = hasUniqueValues (valuesFor (workspace: lib.toLower workspace.network.mac));
        message = "seter.host.workspaces must assign a unique MAC address to every workspace";
      }
      {
        assertion = hasUniqueValues (valuesFor (workspace: workspace.network.tap));
        message = "seter.host.workspaces must assign a unique tap interface to every workspace";
      }
      {
        assertion = lib.all (workspace: workspace.network.tap != cfg.bridge) workspaces;
        message = "seter.host.workspaces tap interfaces must not reuse seter.host.bridge";
      }
      {
        assertion = hasUniqueValues (valuesFor (workspace: lib.toLower workspace.hostname));
        message = "seter.host.workspaces must assign a unique hostname to every workspace";
      }
      {
        assertion = lib.all (runtime: runtime.account != cfg.operatorGroup) (
          builtins.attrValues workspaceRuntime
        );
        message = "seter.host.operatorGroup must not collide with a workspace runtime account";
      }
    ]
    ++ concatMap (workspace: [
      {
        assertion = nonBlank workspace.runner.installable;
        message = "seter.host.workspaces.${workspace.name}.runner.installable must not be blank";
      }
      {
        assertion = workspace.ssh.knownHostKey == null || nonBlank workspace.ssh.knownHostKey;
        message = "seter.host.workspaces.${workspace.name}.ssh.knownHostKey must not be blank";
      }
      {
        assertion = lib.all (secret: nonBlank secret.placeholder) (workspaceSecrets workspace);
        message = "seter.host.workspaces.${workspace.name} secret placeholders must not be blank";
      }
      {
        assertion = lib.all (
          secret:
          !builtins.hasContext secret.sourceFile
          && secret.sourceFile != builtins.storeDir
          && !lib.hasPrefix "${builtins.storeDir}/" secret.sourceFile
        ) (workspaceSecrets workspace);
        message = "seter.host.workspaces.${workspace.name} secret source files must not reference the Nix store or carry Nix string context";
      }
      {
        assertion = lib.all (host: builtins.elem host (allowedSecretHosts workspace)) (
          secretHosts workspace
        );
        message = "seter.host.workspaces.${workspace.name} secret hosts must also be declared as HTTP or passthrough hosts";
      }
    ]) workspaces;

    environment.etc."seter/workspaces.json" = {
      source = registryFile;
      mode = "0444";
    };

    boot.kernelModules = [
      "tun"
      "vhost_net"
      "vhost_vsock"
    ];

    networking.dhcpcd.denyInterfaces = [
      cfg.bridge
    ]
    ++ map (workspace: workspace.network.tap) workspaces;
    networking.networkmanager.unmanaged = [
      cfg.bridge
    ]
    ++ map (workspace: workspace.network.tap) workspaces;

    systemd.services =
      tapServices
      // virtiofsdServices
      // vmServices
      // {
        seter-bridge = {
          description = "Seter workspace bridge";
          wantedBy = [ "multi-user.target" ];
          before = map (name: "seter-tap-${name}.service") (attrNames cfg.workspaces);
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = bridgeUp;
            ExecStop = bridgeDown;
          };
        };
      };

    users.groups = {
      ${cfg.operatorGroup} = { };
    }
    // mapAttrs' (_: runtime: nameValuePair runtime.account { }) workspaceRuntime;
    users.users = mapAttrs' (
      _: runtime:
      nameValuePair runtime.account {
        isSystemUser = true;
        group = runtime.account;
        extraGroups = [ "kvm" ];
      }
    ) workspaceRuntime;

    systemd.tmpfiles.settings."10-seter" = {
      "/var/lib/seter".d = {
        user = "root";
        group = "root";
        mode = "0755";
      };
      "/var/lib/seter/workspaces".d = {
        user = "root";
        group = "root";
        mode = "0711";
      };
      ${lifecycleLockDirectory}.d = {
        user = "root";
        group = "root";
        mode = "0755";
      };
    }
    // mapAttrs' (
      _: runtime:
      nameValuePair runtime.stateDirectory {
        d = {
          user = runtime.account;
          group = runtime.account;
          mode = "0700";
        };
      }
    ) workspaceRuntime
    // mapAttrs' (
      _: runtime:
      nameValuePair runtime.lifecycleLock {
        f = {
          user = "root";
          group = runtime.account;
          mode = "0640";
        };
      }
    ) workspaceRuntime;

    systemd.targets = runtimeTargets;

    # Authorize only exact internal commands for configured workspaces. The
    # privileged command reloads the root-owned registry and constructs the
    # systemd unit name itself; operators never receive general systemctl or
    # unrestricted Seter access through sudo.
    security.sudo.extraRules = lib.optional (lifecycleSudoCommands != [ ]) {
      groups = [ cfg.operatorGroup ];
      runAs = "root";
      commands = lifecycleSudoCommands;
    };

    # These are used by lifecycle commands for strict SSH host-key handling
    # and offline enrollment from the persistent ext4 image.
    environment.systemPackages = [
      cfg.package
      pkgs.e2fsprogs
      pkgs.openssh
    ];

    # DNS and policy enforcement remain separate milestones. The plumbing
    # units expose only the registered TAP and read-only /nix/store share and
    # never invoke runner-provided setup helpers. Only seter-vm-* executes the
    # runner, always as the dedicated unprivileged workspace account.
  };
}
