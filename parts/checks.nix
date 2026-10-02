{ inputs, self, ... }:
{
  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    let
      proxyTrustCa = ../tests/fixtures/proxy-e2e-ca-cert.pem;
      fixtures = import ../tests/fixtures/check-configurations.nix {
        inherit
          inputs
          self
          lib
          pkgs
          system
          proxyTrustCa
          ;
      };
      inherit (fixtures) mkHostWith validWorkspaces identityGuestConfiguration;
      hostConfiguration = fixtures.mkHost validWorkspaces;
      registryFile = hostConfiguration.config.environment.etc."seter/workspaces.json".source;
    in
    {
      checks = {
        inherit (self.packages.${system}) seter;
        nixos-host-module = hostConfiguration.config.system.build.toplevel;
        nixos-guest-module = import ../tests/guest-module.nix {
          inherit
            inputs
            self
            system
            proxyTrustCa
            ;
        };
        development-ports = import ../tests/development-ports.nix {
          inherit pkgs identityGuestConfiguration;
        };
        multi-repository = import ../tests/multi-repository.nix {
          inherit
            inputs
            self
            pkgs
            system
            ;
        };
        local-import = pkgs.runCommand "seter-local-import-check" { nativeBuildInputs = [ pkgs.git ]; } ''
          ${pkgs.python3}/bin/python ${../tests/local-import.py} \
            ${../crates/seter-cli/src/lifecycle/local-bootstrap.sh}
          touch "$out"
        '';
        workspace-registry = import ../tests/workspace-registry.nix {
          inherit
            self
            lib
            pkgs
            system
            fixtures
            hostConfiguration
            ;
          minimalConfiguration = self.nixosConfigurations.minimal;
        };
        workspace-uniqueness = import ../tests/configuration-validation.nix {
          inherit
            inputs
            self
            pkgs
            system
            fixtures
            ;
        };
        status-snapshot = pkgs.runCommand "seter-status-snapshot-check" { } ''
          ${pkgs.python3}/bin/python ${../tests/status-snapshot.py} \
            ${lib.getExe self.packages.${system}.seter} ${registryFile}
          touch "$out"
        '';
        privilege = pkgs.runCommand "seter-privilege-check" { } ''
          ${pkgs.python3}/bin/python ${../tests/privilege.py} \
            ${lib.getExe self.packages.${system}.seter} ${registryFile}
          touch "$out"
        '';
        host-patterns = import ../tests/host-patterns.nix { inherit pkgs; };
        policy-ownership = import ../tests/policy-ownership.nix {
          inherit
            self
            pkgs
            system
            mkHostWith
            validWorkspaces
            ;
        };
      }
      // lib.optionalAttrs (system == "aarch64-linux") {
        arm-qemu-runner = import ../tests/arm-qemu-runner.nix {
          inherit lib pkgs fixtures;
        };
      }
      // lib.optionalAttrs (system == "x86_64-linux") {
        minimal-runner = self.nixosConfigurations.minimal.config.microvm.declaredRunner;
        lifecycle-e2e = import ../tests/lifecycle-e2e.nix {
          inherit
            inputs
            self
            pkgs
            system
            ;
        };
        proxy-trust-e2e = import ../tests/proxy-trust-e2e.nix {
          inherit
            self
            lib
            pkgs
            proxyTrustCa
            ;
        };
        host-runtime = import ../tests/host-runtime.nix {
          inherit
            self
            lib
            pkgs
            system
            validWorkspaces
            ;
        };
        network-isolation = import ../tests/network-isolation.nix {
          inherit self pkgs validWorkspaces;
        };
      };
    };
}
