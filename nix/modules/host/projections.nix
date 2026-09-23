# Runner, registry and active policy are projections of the same host generation.
{
  cfg,
  lib,
  pkgs,
  seterMicrovmModule,
  subnetPrefix,
  parseIpv4,
}:
let
  inherit (lib) mapAttrs mkIf;
  workspaceDefinitions = mapAttrs (
    name: workspace:
    import ../../lib/mk-runner-definition.nix {
      inherit name workspace;
      gateway = cfg.gateway;
      prefixLength = subnetPrefix;
      proxyPort = cfg.proxy.explicitPort;
      proxyCaCertificate = cfg.proxyCaCertificate;
      hypervisor = cfg.runner.hypervisor;
    }
  ) cfg.workspaces;

  workspaceSystems = mapAttrs (
    name: workspace:
    import "${pkgs.path}/nixos/lib/eval-config.nix" {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        seterMicrovmModule
        (import ../guest)
        workspaceDefinitions.${name}.guestModule
        (import ../guest/profiles/default.nix)
        {
          seter.guest = {
            memory = workspace.resources.memoryMiB;
            vcpu = workspace.resources.vcpu;
            ssh.authorizedKeys = workspace.ssh.authorizedKeys;
          };
          boot.kernelPackages = mkIf (
            cfg.runner.hypervisor == "qemu" && pkgs.stdenv.hostPlatform.isAarch64
          ) pkgs.linuxPackages_6_12;
          microvm.qemu.machineOpts =
            mkIf (cfg.runner.hypervisor == "qemu" && pkgs.stdenv.hostPlatform.isAarch64)
              {
                accel = "kvm";
                gic-version = "max";
              };
          # Workspaces are headless. The physical-Mac probe showed that
          # virtual-console initialization can stall under nested ARM KVM.
          console.enable = mkIf (cfg.runner.hypervisor == "qemu" && pkgs.stdenv.hostPlatform.isAarch64) false;
          # Derive the vsock context ID from the already-unique workspace
          # address so two workspaces can never collide. The values are large
          # and unmemorable by construction; they are host-internal identifiers
          # rather than anything an operator configures or reads.
          microvm.vsock.cid = 3 + parseIpv4 workspace.network.address;
        }
      ];
    }
  ) cfg.workspaces;

  workspaceRunners = mapAttrs (_: system: system.config.microvm.declaredRunner) workspaceSystems;

  lifecycleRegistry = {
    version = 7;
    workspaces = mapAttrs (name: workspace: {
      inherit (workspace)
        hostname
        guestProfile
        developmentPorts
        network
        storage
        ;
      defaultRepository = workspace.defaultRepository;
      repositories = mapAttrs (_: repository: {
        inherit (repository) url branch checkoutName;
        credential =
          if repository.credential == null then
            null
          else
            {
              name = repository.credential;
              placeholder = workspace.secrets.${repository.credential}.placeholder;
            };
      }) workspace.resolvedRepositories;
      # hostOverheadMiB sizes the host systemd limit only. It is not guest
      # identity and the CLI has no use for it, so it stays out of the registry.
      resources = {
        inherit (workspace.resources) memoryMiB vcpu cpuQuotaPercent;
      };
      ssh = {
        inherit (workspace.ssh) user;
      };
      runner = {
        path = toString workspaceRunners.${name};
        identity = workspaceDefinitions.${name}.identity;
      };
    }) cfg.workspaces;
  };

  registryFile = pkgs.writeText "seter-workspaces.json" (builtins.toJSON lifecycleRegistry);
  activePolicyFile = pkgs.writeText "seter-active-policy.json" (
    builtins.toJSON {
      version = 1;
      workspaces = mapAttrs (_: workspace: {
        egress = {
          "http-hosts" = map lib.toLower workspace.egress.httpHosts;
          "passthrough-hosts" = map lib.toLower workspace.egress.passthroughHosts;
          tcp = map (
            destination: destination // { host = lib.toLower destination.host; }
          ) workspace.egress.tcp;
        };
      }) cfg.workspaces;
    }
  );

in
{
  inherit
    workspaceDefinitions
    workspaceSystems
    workspaceRunners
    registryFile
    activePolicyFile
    ;
}
