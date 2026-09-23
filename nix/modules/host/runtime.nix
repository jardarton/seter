# Per-workspace host accounts, network plumbing and VM runtime units.
{
  cfg,
  lib,
  pkgs,
  workspaceRunners,
  subnetPrefix,
  lifecycleLockDirectory,
}:
let
  inherit (lib)
    attrNames
    mapAttrs
    mapAttrs'
    mapAttrsToList
    nameValuePair
    optionalAttrs
    ;
  workspaces = mapAttrsToList (name: workspace: workspace // { inherit name; }) cfg.workspaces;
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
      identitySocket = "/run/seter/${name}/virtiofs-identity.sock";
      identityDirectory = "/var/lib/seter/identities/${name}";
      knownHostFile = "/var/lib/seter/known-hosts/${name}";
      stateDirectory = "/var/lib/seter/workspaces/${name}";
    }
  ) cfg.workspaces;

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
        "seter-proxy.service"
      ]
      ++ lib.optional (workspace.egress.tcp != [ ]) "seter-tcp-egress-${name}.service"
      ++ map (service: "seter-gateway-${service}.socket") workspace.hostServices;
      requires = [
        "nftables.service"
        "seter-bridge.service"
        "seter-dns-${name}.service"
        "seter-proxy.service"
      ]
      ++ lib.optional (workspace.egress.tcp != [ ]) "seter-tcp-egress-${name}.service"
      ++ map (service: "seter-gateway-${service}.socket") workspace.hostServices;
      partOf = [ "seter-runtime-${name}.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = tapUp;
        ExecStop = tapDown;
      };
    }
  ) workspaceRuntime;

  identityVirtiofsdServices = mapAttrs' (
    name: runtime:
    let
      inherit (runtime) identityDirectory identitySocket;
      runtimeIdentityDirectory = "/run/credentials/seter-identity-virtiofsd-${name}.service";
      runIdentityVirtiofsd = pkgs.writeShellScript "seter-identity-virtiofsd-${name}" ''
        set -eu
        test "$CREDENTIALS_DIRECTORY" = ${lib.escapeShellArg runtimeIdentityDirectory}
        rm -f ${lib.escapeShellArg identitySocket}
        ${lib.getExe pkgs.virtiofsd} \
          --socket-path=${lib.escapeShellArg identitySocket} \
          --shared-dir="$CREDENTIALS_DIRECTORY" \
          --readonly \
          --posix-acl=always \
          --cache=never \
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
      waitForSocket = pkgs.writeShellScript "seter-identity-virtiofsd-${name}-ready" ''
        set -eu
        for attempt in $(${pkgs.coreutils}/bin/seq 1 100); do
          if test -S ${lib.escapeShellArg identitySocket} && kill -0 "$MAINPID" 2>/dev/null; then
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 0.05
        done
        echo "Workspace SSH Identity socket ${identitySocket} did not become ready" >&2
        exit 1
      '';
    in
    nameValuePair "seter-identity-virtiofsd-${name}" {
      description = "Read-only Workspace SSH Identity for ${name}";
      after = [ "seter-tap-${name}.service" ];
      requires = [ "seter-tap-${name}.service" ];
      bindsTo = [ "seter-tap-${name}.service" ];
      partOf = [ "seter-runtime-${name}.target" ];
      serviceConfig = {
        Type = "exec";
        User = runtime.account;
        Group = runtime.account;
        RuntimeDirectory = runtime.runtimeDirectory;
        RuntimeDirectoryMode = "0700";
        LoadCredential = [
          "ssh_host_ed25519_key:${identityDirectory}/ssh_host_ed25519_key"
          "ssh_host_ed25519_key.pub:${identityDirectory}/ssh_host_ed25519_key.pub"
        ];
        ExecStart = runIdentityVirtiofsd;
        ExecStartPost = waitForSocket;
        TimeoutStopSec = "10s";
        Restart = "on-failure";
        RestartSec = "1s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadOnlyPaths = [ identityDirectory ];
      };
    }
  ) (if cfg.runner.hypervisor == "cloud-hypervisor" then workspaceRuntime else { });

  runtimeTargets = mapAttrs' (
    name: _:
    let
      identityUnit =
        if cfg.runner.hypervisor == "cloud-hypervisor" then
          "seter-identity-virtiofsd-${name}.service"
        else
          "seter-tap-${name}.service";
    in
    nameValuePair "seter-runtime-${name}" {
      description = "Host runtime plumbing for Seter workspace ${name}";
      requires = [ identityUnit ];
      bindsTo = [ identityUnit ];
      after = [ identityUnit ];
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
      runner = workspaceRunners.${name};
      runVm = pkgs.writeShellScript "seter-vm-${name}-run" ''
        set -eu
        exec {lifecycle_lock}<${lib.escapeShellArg lifecycleLock}
        ${pkgs.util-linux}/bin/flock --exclusive "$lifecycle_lock"
        test -x ${runner}/bin/microvm-run
        test -x ${runner}/bin/microvm-shutdown
        exec ${runner}/bin/microvm-run
      '';
      stopVm = pkgs.writeShellScript "seter-vm-${name}-stop" ''
        set -eu
        shutdown=$1
        ${
          if cfg.runner.hypervisor == "qemu" then
            ''
              qmp_socket=$2
              main_pid=''${3:-}
            ''
          else
            ''
              main_pid=''${2:-}
            ''
        }

        # QEMU may have exited independently, in which case systemd expands
        # $MAINPID to no argument while completing the service teardown.
        if [ -z "$main_pid" ] || ! kill -0 "$main_pid" 2>/dev/null; then
          exit 0
        fi

        ${
          if cfg.runner.hypervisor == "qemu" then
            ''
              if [ ! -S "$qmp_socket" ]; then
                echo "QMP socket $qmp_socket is unavailable" >&2
                exit 1
              fi

              # microvm.nix sends Ctrl-Alt-Delete, but Seter's headless QEMU
              # machine has no input handler. Request an ACPI powerdown over
              # the Runner's private QMP socket instead.
              if ! qmp_output=$(
                {
                  printf '%s\n' '{"execute":"qmp_capabilities"}'
                  printf '%s\n' '{"execute":"system_powerdown"}'
                } | ${pkgs.socat}/bin/socat STDIO "UNIX-CONNECT:$qmp_socket"
              ); then
                echo "failed to request guest powerdown over $qmp_socket" >&2
                exit 1
              fi
              printf '%s\n' "$qmp_output"
              if printf '%s\n' "$qmp_output" | ${pkgs.gnugrep}/bin/grep -q '"error"'; then
                echo "QEMU rejected the guest powerdown request" >&2
                exit 1
              fi
            ''
          else
            ''
              "$shutdown"
            ''
        }

        # Do not let systemd terminate the VMM while the guest is flushing and
        # unmounting its persistent filesystems.
        while kill -0 "$main_pid" 2>/dev/null; do
          ${pkgs.coreutils}/bin/sleep 0.1
        done
      '';
    in
    nameValuePair "seter-vm-${name}" {
      description = "Seter microVM for workspace ${name}";
      requires = [ "seter-runtime-${name}.target" ];
      after = [ "seter-runtime-${name}.target" ];
      partOf = [ "seter-runtime-${name}.target" ];
      unitConfig.ConditionPathExists = "${runner}/bin/microvm-run";
      serviceConfig = {
        Type = "simple";
        User = account;
        Group = account;
        WorkingDirectory = stateDirectory;
        ExecStart = runVm;
        ExecStop =
          if cfg.runner.hypervisor == "qemu" then
            "${stopVm} ${runner}/bin/microvm-shutdown ${stateDirectory}/seter-${name}.sock $MAINPID"
          else
            "${stopVm} ${runner}/bin/microvm-shutdown $MAINPID";
        TimeoutStopSec = "60s";
        KillMode = "mixed";
        Restart = "no";
        MemoryMax = (workspace.resources.memoryMiB + workspace.resources.hostOverheadMiB) * 1024 * 1024;
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
      }
      // optionalAttrs (cfg.runner.hypervisor == "qemu") {
        LoadCredential = [
          "ssh_host_ed25519_key:${runtime.identityDirectory}/ssh_host_ed25519_key"
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
  inherit workspaceRuntime;
  config = {
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
      // identityVirtiofsdServices
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
      "/var/lib/seter/identities".d = {
        user = "root";
        group = "root";
        mode = "0700";
      };
      "/var/lib/seter/known-hosts".d = {
        user = "root";
        group = cfg.operatorGroup;
        mode = "0750";
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

    # Workspace identities are host state, not guest-generated project data.
    # Generate them during trusted host activation, before any first boot.
    system.activationScripts.seterWorkspaceState = {
      deps = [
        "users"
        "groups"
      ];
      text = lib.concatStringsSep "\n" (
        mapAttrsToList (name: runtime: ''
          install -d -m 0700 -o root -g root ${lib.escapeShellArg runtime.identityDirectory}
          if ! test -f ${lib.escapeShellArg "${runtime.identityDirectory}/ssh_host_ed25519_key"}; then
            ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" \
              -C ${lib.escapeShellArg "seter workspace ${name}"} \
              -f ${lib.escapeShellArg "${runtime.identityDirectory}/ssh_host_ed25519_key"}
          fi
          chown root:root ${lib.escapeShellArg runtime.identityDirectory}/ssh_host_ed25519_key{,.pub}
          chmod 0600 ${lib.escapeShellArg "${runtime.identityDirectory}/ssh_host_ed25519_key"}
          chmod 0644 ${lib.escapeShellArg "${runtime.identityDirectory}/ssh_host_ed25519_key.pub"}

          install -d -m 0750 -o root -g ${lib.escapeShellArg cfg.operatorGroup} /var/lib/seter/known-hosts
          install -m 0440 -o root -g ${lib.escapeShellArg cfg.operatorGroup} \
            ${lib.escapeShellArg "${runtime.identityDirectory}/ssh_host_ed25519_key.pub"} \
            ${lib.escapeShellArg runtime.knownHostFile}

          install -d -m 0700 -o ${lib.escapeShellArg runtime.account} -g ${lib.escapeShellArg runtime.account} \
            ${lib.escapeShellArg runtime.stateDirectory}
        '') workspaceRuntime
      );
    };

  };
}
