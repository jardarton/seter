{
  inputs,
  self,
  lib,
  pkgs,
  system,
  proxyTrustCa,
}:
let
  mkTestWorkspace =
    {
      ip,
      mac,
      tap,
    }:
    {
      guestProfile = "default";
      repository = {
        url = "https://example.invalid/owner/workspace.git";
        branch = null;
        checkoutName = null;
        credential = null;
      };
      network = {
        address = ip;
        inherit mac tap;
      };
      resources = {
        memoryMiB = 4096;
        vcpu = 2;
        cpuQuotaPercent = 200;
      };
      ssh = {
        user = "seter";
        authorizedKeys = [ ];
      };
      storage = {
        project.sizeMiB = 4096;
        home.sizeMiB = 4096;
        nixStore.sizeMiB = 16384;
      };
      hostServices = [ ];
      egress = {
        httpHosts = [ ];
        passthroughHosts = [ ];
        tcp = [ ];
      };
      secrets = { };
      secretVariables = { };
    };

  hostModuleBase = {
    seter.host.enable = true;
    system.stateVersion = "24.11";
    fileSystems."/" = {
      device = "/dev/vda";
      fsType = "ext4";
    };
    boot.loader.grub.devices = [ "nodev" ];
  };

  mkHostWith =
    host:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.host
        hostModuleBase
        { seter.host = host; }
      ];
    };

  mkHost = workspaces: mkHostWith { inherit workspaces; };

  validWorkspaces = {
    alpha = mkTestWorkspace {
      ip = "10.100.0.10";
      mac = "02:00:00:00:00:10";
      tap = "seter-alpha";
    };
    beta = mkTestWorkspace {
      ip = "10.100.0.11";
      mac = "02:00:00:00:00:11";
      tap = "seter-beta";
    };
  };

  identityWorkspaceEntry =
    (mkTestWorkspace {
      ip = "10.100.0.12";
      mac = "02:00:00:00:00:12";
      tap = "seter-identity";
    })
    // {
      developmentPorts = [ 3000 ];
      repository = {
        url = "https://api.example.com/owner/workspace.git";
        branch = null;
        checkoutName = null;
        credential = "githubToken";
      };
      secrets.githubToken = {
        placeholder = "seter-placeholder-github-0123456789abcdef";
        sourceFile = "/run/secrets/identity-github-token";
        hosts = [ "api.example.com" ];
        headers = [ "authorization" ];
      };
      secretVariables = {
        GITHUB_TOKEN = "githubToken";
        GH_TOKEN = "githubToken";
      };
      egress.httpHosts = [ "api.example.com" ];
    };
  identityHostConfiguration = mkHostWith {
    proxyCaCertificate = builtins.readFile proxyTrustCa;
    workspaces.identity = identityWorkspaceEntry;
  };
  identityRegistryFile =
    identityHostConfiguration.config.environment.etc."seter/workspaces.json".source;
  identityActivePolicyFile =
    identityHostConfiguration.config.environment.etc."seter/policy.json".source;
  identityDesiredPolicyFile = pkgs.writeText "seter-identity-desired-policy.toml" ''
    version = 1
    [workspaces.identity.egress]
    http-hosts = ["api.example.com"]
  '';
  identityRevokedPolicyFile = pkgs.writeText "seter-identity-revoked-policy.toml" ''
    version = 1
    [workspaces.identity.egress]
    http-hosts = []
  '';
  identityWorkspace = import ../../nix/lib/mk-runner-definition.nix {
    name = "identity";
    workspace = identityHostConfiguration.config.seter.host.workspaces.identity;
    gateway = "10.100.0.1";
    prefixLength = 24;
    proxyPort = 18081;
    proxyCaCertificate = builtins.readFile proxyTrustCa;
  };
  identityGuestConfiguration = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.guest
      identityWorkspace.guestModule
      (import ../../nix/modules/guest/profiles/default.nix)
      {
        # Supplied by the host module from the same registry entry.
        seter.guest.memory =
          identityHostConfiguration.config.seter.host.workspaces.identity.resources.memoryMiB;
        system.stateVersion = "24.11";
      }
    ];
  };
  qemuIdentityHostConfiguration = mkHostWith {
    runner.hypervisor = "qemu";
    proxyCaCertificate = builtins.readFile proxyTrustCa;
    workspaces.identity = identityWorkspaceEntry // {
      resources = identityWorkspaceEntry.resources // {
        vcpu = 4;
      };
    };
  };
  qemuIdentityWorkspace = import ../../nix/lib/mk-runner-definition.nix {
    name = "identity";
    workspace = qemuIdentityHostConfiguration.config.seter.host.workspaces.identity;
    gateway = "10.100.0.1";
    prefixLength = 24;
    proxyPort = 18081;
    proxyCaCertificate = builtins.readFile proxyTrustCa;
    hypervisor = "qemu";
  };
  qemuIdentityGuestConfiguration = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.guest
      qemuIdentityWorkspace.guestModule
      (import ../../nix/modules/guest/profiles/default.nix)
      {
        seter.guest = {
          memory = qemuIdentityHostConfiguration.config.seter.host.workspaces.identity.resources.memoryMiB;
          vcpu = qemuIdentityHostConfiguration.config.seter.host.workspaces.identity.resources.vcpu;
        };
        boot.kernelPackages = lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 pkgs.linuxPackages_6_12;
        microvm.qemu.machineOpts = lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 {
          accel = "kvm";
          gic-version = "max";
        };
        console.enable = lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 false;
        system.stateVersion = "24.11";
      }
    ];
  };

in
{
  inherit
    mkTestWorkspace
    hostModuleBase
    mkHostWith
    mkHost
    validWorkspaces
    identityWorkspaceEntry
    identityHostConfiguration
    identityRegistryFile
    identityActivePolicyFile
    identityDesiredPolicyFile
    identityRevokedPolicyFile
    identityWorkspace
    identityGuestConfiguration
    qemuIdentityHostConfiguration
    qemuIdentityWorkspace
    qemuIdentityGuestConfiguration
    ;
}
