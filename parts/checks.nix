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
      minimalStoreSocket = (builtins.head self.nixosConfigurations.minimal.config.microvm.shares).socket;

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

      gatewayIpRejected = configurationRejected {
        broken = mkWorkspace {
          ip = "10.100.0.1";
          mac = "02:00:00:00:00:12";
          tap = "seter-broken";
        };
      };

      networkIpRejected = configurationRejected {
        broken = mkWorkspace {
          ip = "10.100.0.0";
          mac = "02:00:00:00:00:12";
          tap = "seter-broken";
        };
      };

      bridgeTapRejected = configurationRejected {
        broken = mkWorkspace {
          ip = "10.100.0.12";
          mac = "02:00:00:00:00:12";
          tap = "seter0";
        };
      };

      outOfSubnetGatewayRejected =
        !(builtins.tryEval (
          builtins.deepSeq
            (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.host
                hostModuleBase
                {
                  seter.host = {
                    gateway = "10.101.0.1";
                    workspaces = validWorkspaces;
                  };
                }
              ];
            }).config.system.build.toplevel.drvPath
            true
        )).success;

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
          assert minimalStoreSocket == "/run/seter/minimal/virtiofs-ro-store.sock";
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
          assert gatewayIpRejected;
          assert networkIpRejected;
          assert bridgeTapRejected;
          assert outOfSubnetGatewayRejected;
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

        host-runtime = pkgs.testers.runNixOSTest {
          name = "seter-host-runtime";

          nodes.machine = {
            imports = [ self.nixosModules.host ];

            seter.host = {
              enable = true;
              workspaces.alpha = validWorkspaces.alpha;
            };

            virtualisation.memorySize = 1024;
            system.stateVersion = "24.11";
          };

          testScript = ''
            start_all()

            machine.wait_for_unit("seter-bridge.service")
            machine.succeed("ip link show dev seter0")
            machine.succeed("ip -4 address show dev seter0 | grep -F '10.100.0.1/24'")
            machine.fail("ip link show dev seter-alpha")

            machine.succeed("systemctl start seter-runtime-alpha.target")
            machine.wait_for_unit("seter-tap-alpha.service")
            machine.wait_for_unit("seter-virtiofsd-alpha.service")
            machine.succeed("ip link show dev seter-alpha | grep -F 'master seter0'")
            machine.succeed("account=$(stat -c %U /var/lib/seter/workspaces/alpha); uid=$(id -u $account); ip tuntap show dev seter-alpha | grep -F \"user $uid\"")
            machine.succeed("test $(stat -c %a /var/lib/seter/workspaces/alpha) = 700")
            machine.succeed("ip tuntap show dev seter-alpha | grep -F 'multi_queue'")
            machine.succeed("test -S /run/seter/alpha/virtiofs-ro-store.sock")
            machine.succeed("account=$(stat -c %U /var/lib/seter/workspaces/alpha); uid=$(id -u $account); main=$(systemctl show --value --property MainPID seter-virtiofsd-alpha.service); test $(awk '/^Uid:/ { print $2 }' /proc/$main/status) = $uid")
            machine.succeed("stat -c %A /run/seter/alpha/virtiofs-ro-store.sock | grep -E '^s[rwx-]{6}---$'")
            machine.succeed("stat -c %G /run/seter/alpha/virtiofs-ro-store.sock | grep -E '^seter-alpha-[0-9a-f]{8}$'")
            machine.succeed("main=$(systemctl show --value --property MainPID seter-virtiofsd-alpha.service); for pid in $(cat /proc/$main/task/$main/children); do tr '\\0' ' ' < /proc/$pid/cmdline; done | grep -F -- '--shared-dir=/nix/store'")
            machine.succeed("main=$(systemctl show --value --property MainPID seter-virtiofsd-alpha.service); for pid in $(cat /proc/$main/task/$main/children); do tr '\\0' ' ' < /proc/$pid/cmdline; done | grep -F -- '--readonly'")

            machine.succeed("systemctl stop seter-runtime-alpha.target")
            machine.wait_until_fails("ip link show dev seter-alpha")
            machine.wait_until_fails("test -e /run/seter/alpha/virtiofs-ro-store.sock")
            machine.succeed("test $(systemctl show --value --property Result seter-virtiofsd-alpha.service) = success")
            machine.succeed("systemctl is-active --quiet seter-bridge.service")
            machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")

            machine.succeed("systemctl stop seter-bridge.service")
            machine.succeed("ip link add name seter0 type bridge")
            machine.fail("systemctl start seter-bridge.service")
            machine.succeed("ip link show dev seter0")
            machine.succeed("ip link delete dev seter0")
            machine.succeed("systemctl reset-failed seter-bridge.service")
          '';
        };
      };
    };
}
