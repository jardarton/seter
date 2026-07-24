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
      mkWorkspace =
        {
          ip,
          mac,
          tap,
        }:
        self.lib.mkWorkspace {
          runnerInstallable = "github:example/project#nixosConfigurations.guest.config.microvm.declaredRunner";
          inherit ip mac tap;
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

      mkHost =
        workspaces:
        inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.host
            hostModuleBase
            { seter.host = { inherit workspaces; }; }
          ];
        };

      validWorkspaces = {
        alpha = mkWorkspace {
          ip = "10.100.0.10";
          mac = "02:00:00:00:00:10";
          tap = "seter-alpha";
        };
        beta = mkWorkspace {
          ip = "10.100.0.11";
          mac = "02:00:00:00:00:11";
          tap = "seter-beta";
        };
      };

      hostConfiguration = mkHost validWorkspaces;
      registryFile = hostConfiguration.config.environment.etc."seter/workspaces.json".source;

      configurationRejected =
        workspaces:
        !(builtins.tryEval (builtins.deepSeq (mkHost workspaces).config.system.build.toplevel.drvPath true))
        .success;

      configurationAccepted =
        workspaces:
        (builtins.tryEval (builtins.deepSeq (mkHost workspaces).config.system.build.toplevel.drvPath true))
        .success;

      duplicateIpRejected = configurationRejected {
        alpha = validWorkspaces.alpha;
        beta = validWorkspaces.beta // {
          network = validWorkspaces.beta.network // {
            address = validWorkspaces.alpha.network.address;
          };
        };
      };

      duplicateMacRejected = configurationRejected {
        alpha = validWorkspaces.alpha;
        beta = validWorkspaces.beta // {
          network = validWorkspaces.beta.network // {
            mac = validWorkspaces.alpha.network.mac;
          };
        };
      };

      duplicateTapRejected = configurationRejected {
        alpha = validWorkspaces.alpha;
        beta = validWorkspaces.beta // {
          network = validWorkspaces.beta.network // {
            tap = validWorkspaces.alpha.network.tap;
          };
        };
      };

      duplicateHostnameRejected = configurationRejected {
        alpha = validWorkspaces.alpha;
        beta = validWorkspaces.beta // {
          hostname = "alpha.vm";
        };
      };

      invalidIpRejected = configurationRejected {
        broken = mkWorkspace {
          ip = "10.100.0.999";
          mac = "02:00:00:00:00:12";
          tap = "seter-broken";
        };
      };

      outOfSubnetIpRejected = configurationRejected {
        broken = mkWorkspace {
          ip = "10.101.0.12";
          mac = "02:00:00:00:00:12";
          tap = "seter-broken";
        };
      };

      blankInstallableRejected = configurationRejected {
        broken = validWorkspaces.alpha // {
          runner.installable = "   ";
        };
      };

      blankKnownHostKeyRejected = configurationRejected {
        broken = validWorkspaces.alpha // {
          ssh = validWorkspaces.alpha.ssh // {
            knownHostKey = "   ";
          };
        };
      };

      blankSecretPlaceholderRejected = configurationRejected {
        broken = validWorkspaces.alpha // {
          egress.httpHosts = [ "api.example.com" ];
          secrets.token = {
            placeholder = "   ";
            sourceFile = "/run/secrets/token";
            hosts = [ "api.example.com" ];
          };
        };
      };

      storeSecretSourceRejected = configurationRejected {
        broken = validWorkspaces.alpha // {
          egress.httpHosts = [ "api.example.com" ];
          secrets.token = {
            placeholder = "placeholder-token";
            sourceFile = "/nix/store/example-secret";
            hosts = [ "api.example.com" ];
          };
        };
      };

      caseInsensitiveSecretHostAccepted = configurationAccepted {
        alpha = validWorkspaces.alpha // {
          egress.httpHosts = [ "API.Example.COM" ];
          secrets.token = {
            placeholder = "placeholder-token";
            sourceFile = "/run/secrets/token";
            hosts = [ "api.example.com" ];
          };
        };
      };
    in
    {
      checks = {
        inherit (self.packages.${system}) seter;

        nixos-host-module = hostConfiguration.config.system.build.toplevel;

        workspace-registry =
          pkgs.runCommand "seter-workspace-registry-check"
            {
              nativeBuildInputs = [
                pkgs.jq
                self.packages.${system}.seter
              ];
            }
            ''
              jq -e '
                .version == 1 and
                (.workspaces | keys == ["alpha", "beta"]) and
                (.workspaces.alpha.hostname == "alpha.vm") and
                (.workspaces.alpha.network.address == "10.100.0.10") and
                (.workspaces.alpha.network.mac == "02:00:00:00:00:10") and
                (.workspaces.alpha.resources.memoryMiB == 4096) and
                (.workspaces.alpha.resources.cpuQuotaPercent == 200) and
                (.workspaces.alpha | has("egress") | not) and
                (.workspaces.alpha | has("secrets") | not)
              ' ${registryFile}

              export SETER_REGISTRY=${registryFile}
              test "$(seter list)" = $'alpha\nbeta'
              test "$(seter ip alpha)" = "10.100.0.10"

              touch "$out"
            '';

        workspace-uniqueness =
          assert duplicateIpRejected;
          assert duplicateMacRejected;
          assert duplicateTapRejected;
          assert duplicateHostnameRejected;
          assert invalidIpRejected;
          assert outOfSubnetIpRejected;
          assert blankInstallableRejected;
          assert blankKnownHostKeyRejected;
          assert blankSecretPlaceholderRejected;
          assert storeSecretSourceRejected;
          assert caseInsensitiveSecretHostAccepted;
          pkgs.runCommand "seter-workspace-uniqueness-check" { } ''
            touch "$out"
          '';

        nixos-guest-module =
          (inputs.nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.guest
              {
                seter.guest.enable = true;
                system.stateVersion = "24.11";
              }
            ];
          }).config.system.build.toplevel;

      }
      // lib.optionalAttrs (system == "x86_64-linux") {
        minimal-runner = self.nixosConfigurations.minimal.config.microvm.declaredRunner;
      };
    };
}
