{
  config,
  lib,
  pkgs,
  seterMicrovmModule,
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
    mkAfter
    nameValuePair
    mkOption
    types
    ;

  workspaceType = types.submodule (import ./workspace.nix);
  defaultPackage = pkgs.callPackage ../../package.nix { };
  lifecycleLockDirectory = "/run/lock/seter";
  workspaces = mapAttrsToList (name: workspace: workspace // { inherit name; }) cfg.workspaces;

  policyRaw =
    if cfg.policyFile == null then
      {
        version = 1;
        workspaces = { };
      }
    else
      builtins.fromTOML (builtins.readFile cfg.policyFile);
  policyWorkspaces = policyRaw.workspaces or { };
  policyEgressFor = value: value.egress or { };
  policyHttpFor = value: (policyEgressFor value)."http-hosts" or [ ];
  policyPassthroughFor = value: (policyEgressFor value)."passthrough-hosts" or [ ];
  policyTcpFor = value: (policyEgressFor value).tcp or [ ];
  policyWorkspaceDefinitions = mapAttrs (_: value: {
    egress.httpHosts = mkAfter (policyHttpFor value);
    egress.passthroughHosts = mkAfter (policyPassthroughFor value);
    egress.tcp = mkAfter (policyTcpFor value);
  }) policyWorkspaces;

  parseIpv4 = import ../../lib/ipv4.nix { inherit lib; };
  subnetPrefix = lib.toInt (builtins.elemAt (lib.splitString "/" cfg.subnet) 1);

  validation = import ./validation.nix {
    inherit
      cfg
      lib
      pkgs
      config
      workspaces
      workspaceRuntime
      policyRaw
      policyWorkspaces
      parseIpv4
      subnetPrefix
      ;
  };

  projections = import ./projections.nix {
    inherit
      cfg
      lib
      pkgs
      seterMicrovmModule
      subnetPrefix
      parseIpv4
      ;
  };
  inherit (projections) workspaceRunners registryFile activePolicyFile;

  runtime = import ./runtime.nix {
    inherit
      cfg
      lib
      pkgs
      workspaceRunners
      subnetPrefix
      lifecycleLockDirectory
      ;
  };
  inherit (runtime) workspaceRuntime;

  lifecycleSudoCommands = concatMap (
    name:
    (map
      (operation: {
        command = "${lib.getExe cfg.package} ${operation} ${name}";
        options = [ "NOPASSWD" ];
      })
      [
        "__start"
        "__stop"
        "__audit"
      ]
    )
    ++
      map
        (flags: {
          command = "${lib.getExe cfg.package} __reset ${name} ${flags}";
          options = [ "NOPASSWD" ];
        })
        [
          "--home"
          "--nix-store"
          "--home --nix-store"
        ]
  ) (attrNames cfg.workspaces);
  gcSudoCommand = {
    command = "${lib.getExe cfg.package} __gc";
    options = [ "NOPASSWD" ];
  };
  destroyProjectSudoCommands = map (name: {
    command = "${lib.getExe cfg.package} __destroy-project ${name}";
    options = [ "NOPASSWD" ];
  }) (attrNames cfg.workspaces);

in
{
  imports = [
    ./dns.nix
    ./host-services.nix
    ./network-policy.nix
    ./proxy.nix
    ./tcp-egress.nix
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

    generated = {
      dnsPorts = mkOption {
        internal = true;
        readOnly = true;
        type = types.attrsOf types.port;
        default = import ./dns-ports.nix {
          inherit lib;
          workspaces = cfg.workspaces;
        };
      };
      tcpSets = mkOption {
        internal = true;
        readOnly = true;
        type = types.attrsOf types.str;
        default = import ./tcp-egress-sets.nix {
          inherit lib;
          workspaces = cfg.workspaces;
        };
      };
    };

    package = mkOption {
      type = types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "the Seter package from this module's source";
      description = "Seter CLI package installed on the host and authorized for lifecycle helpers.";
    };

    runner.hypervisor = mkOption {
      type = types.enum [
        "cloud-hypervisor"
        "qemu"
      ];
      default = "cloud-hypervisor";
      description = ''
        VMM used for trusted Workspace Runners. QEMU selects the fw_cfg SSH
        identity channel and, on aarch64-linux, the validated Linux 6.12 LTS
        guest kernel. Cloud Hypervisor remains the native-Linux default.
      '';
    };

    operatorGroup = mkOption {
      type = types.strMatching "[a-z_][a-z0-9_-]*";
      default = "seter-operators";
      description = "Host group allowed to start and stop registered Seter workspaces without a sudo password.";
    };

    proxyCaCertificate = mkOption {
      type = types.nullOr types.lines;
      default = null;
      description = "Reviewed public interception CA certificate installed in every trusted Runner.";
    };

    policyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Consumer-owned TOML Policy File imported into effective workspace Policy Grants.";
    };
  };

  config = mkIf cfg.enable (
    lib.mkMerge [
      {
        seter.host.workspaces = policyWorkspaceDefinitions;

        # The physical-Mac gate isolated nested-KVM hangs to the bootstrap Host's
        # latest kernel. Keep both ARM virtualization layers on the accepted LTS.
        boot.kernelPackages = mkIf (
          cfg.runner.hypervisor == "qemu" && pkgs.stdenv.hostPlatform.isAarch64
        ) pkgs.linuxPackages_6_12;

        assertions = validation.assertions;

        environment.etc = {
          "seter/workspaces.json" = {
            source = registryFile;
            mode = "0444";
          };
          "seter/policy.json" = {
            source = activePolicyFile;
            mode = "0444";
          };
        }
        // mapAttrs' (
          name: runner:
          nameValuePair "seter/runners/${name}" {
            source = runner;
          }
        ) workspaceRunners;

        # Runners are part of the trusted NixOS generation. The /etc entries above
        # already place each closure in the system closure; declaring them again as
        # explicit system dependencies keeps that rooting guarantee independent of
        # how the /etc layout may later change. Older NixOS generations therefore
        # retain the runners needed for rollback.
        system.extraDependencies = builtins.attrValues workspaceRunners;

        # Authorize only exact internal commands for configured workspaces. The
        # privileged command reloads the root-owned registry and constructs the
        # systemd unit name itself; operators never receive general systemctl or
        # unrestricted Seter access through sudo.
        security.sudo.extraRules = [
          {
            groups = [ cfg.operatorGroup ];
            runAs = "root";
            commands = lifecycleSudoCommands ++ destroyProjectSudoCommands ++ [ gcSudoCommand ];
          }
        ];

        # These are used by lifecycle commands and Workspace SSH Identity creation.
        environment.systemPackages = [
          cfg.package
          pkgs.openssh
        ];

        # The plumbing units expose only the registered TAP and read-only
        # Workspace SSH Identity. Only seter-vm-* executes the Runner, always as
        # the dedicated unprivileged workspace account.
      }
      runtime.config
    ]
  );
}
