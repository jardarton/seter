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
          knownHostKey ? null,
        }:
        self.lib.mkWorkspace {
          runnerInstallable = "github:example/project#nixosConfigurations.guest.config.microvm.declaredRunner";
          inherit
            ip
            knownHostKey
            mac
            tap
            ;
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
          knownHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey alpha-test";
        };
        beta = mkWorkspace {
          ip = "10.100.0.11";
          mac = "02:00:00:00:00:11";
          tap = "seter-beta";
        };
      };

      dnsPortsFor = workspaces: import ../nix/modules/host/dns-ports.nix { inherit lib workspaces; };
      workspaceDnsPorts = dnsPortsFor validWorkspaces;
      alphaDnsPort = workspaceDnsPorts.alpha;
      betaDnsPort = workspaceDnsPorts.beta;
      alphaDnsPortWithEarlierWorkspace = (dnsPortsFor ({ aardvark = { }; } // validWorkspaces)).alpha;

      hostConfiguration = mkHost validWorkspaces;
      registryFile = hostConfiguration.config.environment.etc."seter/workspaces.json".source;
      minimalStoreSocket = (builtins.head self.nixosConfigurations.minimal.config.microvm.shares).socket;
      alphaDeviceAllow =
        hostConfiguration.config.systemd.services.seter-vm-alpha.serviceConfig.DeviceAllow;
      alphaTapRequires = hostConfiguration.config.systemd.services.seter-tap-alpha.requires;
      dnsService = hostConfiguration.config.systemd.services.seter-dns-alpha;
      nftablesConfig = hostConfiguration.config.networking.nftables;
      lifecycleSudoRules = lib.filter (
        rule: builtins.elem "seter-operators" (rule.groups or [ ])
      ) hostConfiguration.config.security.sudo.extraRules;
      lifecycleSudoCommands = lib.concatMap (
        rule: if builtins.elem "seter-operators" (rule.groups or [ ]) then rule.commands else [ ]
      ) hostConfiguration.config.security.sudo.extraRules;
      lifecycleHelper = lib.getExe hostConfiguration.config.seter.host.package;

      fakeRunner = pkgs.runCommand "seter-fake-runner" { } ''
        mkdir -p "$out/bin"
        cat > "$out/bin/microvm-run" <<'EOF'
        #!${pkgs.runtimeShell}
        set -eu
        touch fake-vm-started
        trap 'exit 0' TERM INT
        while true; do
          ${pkgs.coreutils}/bin/sleep 1 &
          wait $! || true
        done
        EOF
        cat > "$out/bin/microvm-shutdown" <<'EOF'
        #!${pkgs.runtimeShell}
        set -eu
        kill -TERM "$MAINPID"
        while kill -0 "$MAINPID" 2>/dev/null; do
          ${pkgs.coreutils}/bin/sleep 0.1
        done
        EOF
        chmod +x "$out/bin/microvm-run" "$out/bin/microvm-shutdown"
      '';

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
          assert builtins.elem "vhost_vsock" hostConfiguration.config.boot.kernelModules;
          assert builtins.elem "/dev/vhost-vsock rw" alphaDeviceAllow;
          assert builtins.elem "nftables.service" alphaTapRequires;
          assert builtins.elem "seter-dns-alpha.service" alphaTapRequires;
          assert builtins.elem "seter-bridge.service" dnsService.requires;
          assert builtins.elem "nftables.service" dnsService.requires;
          assert alphaDnsPort == alphaDnsPortWithEarlierWorkspace;
          assert alphaDnsPort != betaDnsPort;
          assert builtins.elem "alpha.vm" hostConfiguration.config.networking.hosts."10.100.0.10";
          assert builtins.elem alphaDnsPort
            hostConfiguration.config.networking.firewall.interfaces.seter0.allowedTCPPorts;
          assert builtins.elem alphaDnsPort
            hostConfiguration.config.networking.firewall.interfaces.seter0.allowedUDPPorts;
          assert nftablesConfig.enable;
          assert nftablesConfig.tables.seter_l2.family == "bridge";
          assert nftablesConfig.tables.seter_l3.family == "inet";
          assert nftablesConfig.tables.seter_dns.family == "inet";
          assert builtins.any (
            entry: entry.command == "${lifecycleHelper} __start alpha" && builtins.elem "NOPASSWD" entry.options
          ) lifecycleSudoCommands;
          assert builtins.any (
            entry: entry.command == "${lifecycleHelper} __stop alpha" && builtins.elem "NOPASSWD" entry.options
          ) lifecycleSudoCommands;
          assert lib.all (rule: rule.runAs == "root") lifecycleSudoRules;
          assert lib.all (entry: !(lib.hasInfix "*" entry.command)) lifecycleSudoCommands;
          pkgs.runCommand "seter-workspace-registry-check"
            {
              nativeBuildInputs = [
                pkgs.jq
                pkgs.util-linux
                self.packages.${system}.seter
              ];
            }
            ''
              jq -e '
                .version == 2 and
                (.workspaces | keys == ["alpha", "beta"]) and
                (.workspaces.alpha.hostname == "alpha.vm") and
                (.workspaces.alpha.network.address == "10.100.0.10") and
                (.workspaces.alpha.network.mac == "02:00:00:00:00:10") and
                (.workspaces.alpha.resources.memoryMiB == 4096) and
                (.workspaces.alpha.resources.cpuQuotaPercent == 200) and
                (.workspaces.alpha.ssh.knownHostKey == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey alpha-test") and
                (.workspaces.alpha.storage.image == "alpha-project.img") and
                (.workspaces.alpha | has("egress") | not) and
                (.workspaces.alpha | has("secrets") | not)
              ' ${registryFile}

              export SETER_REGISTRY=${registryFile}
              test "$(seter list)" = $'alpha\nbeta'
              test "$(seter ip alpha)" = "10.100.0.10"

              mkdir -p test-bin
              cat > test-bin/systemctl <<'EOF'
              #!${pkgs.runtimeShell}
              if test "$1" = show; then
                printf '%s\n' ActiveState=inactive SubState=dead MainPID=0
              fi
              EOF
              cat > test-bin/nix <<'EOF'
              #!${pkgs.runtimeShell}
              echo ${fakeRunner}
              EOF
              cat > test-bin/debugfs <<'EOF'
              #!${pkgs.runtimeShell}
              echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey seter-test'
              EOF
              cat > test-bin/ssh-keygen <<'EOF'
              #!${pkgs.runtimeShell}
              echo '256 SHA256:test seter-test (ED25519)'
              EOF
              chmod +x test-bin/systemctl test-bin/nix test-bin/debugfs test-bin/ssh-keygen
              export SETER_SYSTEMCTL=$PWD/test-bin/systemctl
              export SETER_NIX=$PWD/test-bin/nix
              export SETER_STATE_DIR=$PWD/state
              export SETER_GCROOT_DIR=$PWD/gcroots
              seter update alpha
              test "$(readlink state/alpha/current)" = "${fakeRunner}"
              test "$(readlink gcroots/alpha)" = "${fakeRunner}"
              test -z "$(find gcroots -maxdepth 1 -name '.alpha.pending-*' -print -quit)"
              set +e
              seter status alpha > status
              status_code=$?
              set -e
              test "$status_code" = 3
              grep -F 'state: stopped' status
              touch state/alpha/alpha-project.img
              export SETER_DEBUGFS=$PWD/test-bin/debugfs
              export SETER_SSH_KEYGEN=$PWD/test-bin/ssh-keygen

              (
                flock --exclusive 9
                touch host-key-lock-held
                sleep 30
              ) 9>state/alpha/lifecycle.lock &
              lock_pid=$!
              for attempt in $(seq 1 100); do
                test -e host-key-lock-held && break
                sleep 0.01
              done
              test -e host-key-lock-held
              set +e
              seter ssh-host-key alpha > /dev/null 2> host-key-lock-error
              lock_code=$?
              set -e
              test "$lock_code" = 1
              grep -F 'workspace lifecycle is busy' host-key-lock-error
              kill "$lock_pid"
              wait "$lock_pid" 2>/dev/null || true

              seter ssh-host-key alpha > host-key 2> fingerprint
              grep -F 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey' host-key
              grep -F 'SHA256:test' fingerprint

              rm gcroots/alpha
              mkdir gcroots/alpha
              set +e
              seter update alpha > /dev/null 2> gcroot-error
              update_code=$?
              set -e
              test "$update_code" = 1
              grep -F 'it was retained to protect the installed runner' gcroot-error
              pending=$(find gcroots -maxdepth 1 -type l -name '.alpha.pending-*' -print -quit)
              test -n "$pending"
              test "$(readlink "$pending")" = "${fakeRunner}"
              test "$(readlink state/alpha/current)" = "${fakeRunner}"

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

        lifecycle-e2e = import ../tests/lifecycle-e2e.nix {
          inherit
            inputs
            self
            pkgs
            system
            ;
        };

        host-runtime = pkgs.testers.runNixOSTest {
          name = "seter-host-runtime";

          nodes.machine = {
            imports = [ self.nixosModules.host ];

            environment.systemPackages = [ self.packages.${system}.seter ];

            users.users.operator = {
              isNormalUser = true;
              extraGroups = [ "seter-operators" ];
            };
            users.users.outsider.isNormalUser = true;

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
            machine.wait_for_unit("nftables.service")
            machine.fail("systemctl is-active --quiet seter-dns-alpha.service")
            machine.succeed("nft list table bridge seter_l2")
            machine.succeed("nft list table inet seter_l3")
            machine.succeed("nft list table inet seter_dns")
            machine.succeed("ip link show dev seter0")
            machine.succeed("ip -4 address show dev seter0 | grep -F '10.100.0.1/24'")
            machine.fail("ip link show dev seter-alpha")

            machine.succeed("systemctl start seter-runtime-alpha.target")
            machine.wait_for_unit("seter-dns-alpha.service")
            machine.wait_for_unit("seter-tap-alpha.service")
            machine.wait_for_unit("seter-virtiofsd-alpha.service")
            machine.succeed("ip link show dev seter-alpha | grep -F 'master seter0'")
            machine.succeed("bridge -details link show dev seter-alpha | grep -F 'isolated on'")
            machine.succeed("account=$(stat -c %U /var/lib/seter/workspaces/alpha); uid=$(id -u $account); ip tuntap show dev seter-alpha | grep -F \"user $uid\"")
            machine.succeed("test $(stat -c %a /var/lib/seter/workspaces/alpha) = 700")
            machine.succeed("account=$(stat -c %G /run/lock/seter/alpha.lock); test \"$account\" = $(stat -c %U /var/lib/seter/workspaces/alpha)")
            machine.succeed("test $(stat -c %U /run/lock/seter/alpha.lock) = root")
            machine.succeed("test $(stat -c %a /run/lock/seter/alpha.lock) = 640")
            machine.fail("account=$(stat -c %G /run/lock/seter/alpha.lock); runuser -u $account -- rm -f /run/lock/seter/alpha.lock")
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
            machine.wait_until_fails("systemctl is-active --quiet seter-dns-alpha.service")
            machine.succeed("test $(systemctl show --value --property Result seter-virtiofsd-alpha.service) = success")
            machine.succeed("systemctl is-active --quiet seter-bridge.service")
            machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")

            machine.succeed("mkdir -p /nix/var/nix/gcroots/per-project; ln -s ${fakeRunner} /nix/var/nix/gcroots/per-project/alpha")
            machine.succeed("ln -s ${fakeRunner} /var/lib/seter/workspaces/alpha/current")
            machine.succeed("set +e; seter status alpha > /tmp/seter-status; code=$?; set -e; test $code = 3; grep -F 'state: stopped' /tmp/seter-status")
            machine.fail("su - outsider -c 'seter up alpha'")
            machine.succeed("set +e; su - operator -c 'seter up missing' 2> /tmp/missing-workspace; code=$?; set -e; test $code = 1; grep -F 'is not configured' /tmp/missing-workspace")
            machine.fail("su - operator -c 'sudo -n true'")
            machine.fail("su - operator -c 'sudo -n -u outsider ${lifecycleHelper} __start alpha'")
            machine.fail("su - operator -c 'seter __start alpha'")
            machine.succeed("su - operator -c 'seter up alpha' | grep -F 'Started alpha at 10.100.0.10'")
            machine.wait_for_unit("seter-vm-alpha.service")
            machine.wait_until_succeeds("test -e /var/lib/seter/workspaces/alpha/fake-vm-started")
            machine.succeed("test $(readlink /var/lib/seter/workspaces/alpha/booted) = ${fakeRunner}")
            machine.succeed("account=$(stat -c %U /var/lib/seter/workspaces/alpha); main=$(systemctl show --value --property MainPID seter-vm-alpha.service); test $(awk '/^Name:/ { print $2 }' /proc/$main/status) = microvm-run")
            machine.succeed("test $(systemctl show --value --property MemoryMax seter-vm-alpha.service) = 4294967296")
            machine.succeed("test $(systemctl show --value --property CPUQuotaPerSecUSec seter-vm-alpha.service) = 2s")
            machine.succeed("systemctl is-active --quiet seter-runtime-alpha.target")
            machine.fail("flock --nonblock /run/lock/seter/alpha.lock true")
            machine.succeed("seter status alpha | grep -F 'state: running'")
            machine.succeed("set +e; seter update alpha > /tmp/seter-update 2>&1; code=$?; set -e; test $code = 1; grep -F 'stop it before updating' /tmp/seter-update")
            machine.succeed("su - operator -c 'seter down alpha' | grep -F 'Stopped alpha'")
            machine.wait_until_fails("test -e /var/lib/seter/workspaces/alpha/booted")
            machine.succeed("flock --nonblock /run/lock/seter/alpha.lock true")
            machine.wait_until_fails("ip link show dev seter-alpha")
            machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")

            machine.succeed("systemctl stop seter-bridge.service")
            machine.succeed("ip link add name seter0 type bridge")
            machine.fail("systemctl start seter-bridge.service")
            machine.succeed("ip link show dev seter0")
            machine.succeed("ip link delete dev seter0")
            machine.succeed("systemctl reset-failed seter-bridge.service")
          '';
        };

        network-isolation = pkgs.testers.runNixOSTest {
          name = "seter-network-isolation";

          nodes.machine = {
            imports = [ self.nixosModules.host ];

            environment.systemPackages = [
              pkgs.bind
              pkgs.dnsmasq
              pkgs.iproute2
              pkgs.iputils
              pkgs.jq
              pkgs.nftables
            ];

            # The test deliberately enables forwarding and disables the
            # ordinary NixOS firewall. The Seter-owned policy must still keep
            # workspace interfaces fail-closed on a permissive host.
            boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
            networking.firewall.enable = false;
            # Exercise the strongest reload mode: Seter's managed tables must
            # be recreated as part of the same transaction after a full flush.
            networking.nftables.flushRuleset = true;

            seter.host = {
              enable = true;
              dns.upstreamServers = [ "11.0.0.2" ];
              workspaces = validWorkspaces // {
                alpha = validWorkspaces.alpha // {
                  egress.httpHosts = [ "allowed.example" ];
                };
              };
            };

            virtualisation.memorySize = 1024;
            system.stateVersion = "24.11";
          };

          testScript = ''
            start_all()

            machine.wait_for_unit("seter-bridge.service")
            machine.wait_for_unit("nftables.service")
            machine.succeed("systemctl start seter-dns-alpha.service seter-dns-beta.service")
            machine.wait_for_unit("seter-dns-alpha.service")
            machine.wait_for_unit("seter-dns-beta.service")
            machine.succeed("nft list table bridge seter_l2")
            machine.succeed("nft list table inet seter_l3")
            machine.succeed("nft list table inet seter_dns")

            # Use network namespaces as lightweight hostile guests. Their host
            # veth names and guest identities match the registered TAPs, so
            # packets traverse the exact generated nftables rules.
            machine.succeed("ip netns add alpha; ip link add seter-alpha type veth peer name eth0 netns alpha")
            machine.succeed("ip link set seter-alpha master seter0; bridge link set dev seter-alpha isolated on; ip link set seter-alpha up")
            machine.succeed("ip -n alpha link set lo up; ip -n alpha link set eth0 address 02:00:00:00:00:10; ip -n alpha link set eth0 up; ip -n alpha address add 10.100.0.10/24 dev eth0; ip -n alpha route add default via 10.100.0.1")

            machine.succeed("ip netns add beta; ip link add seter-beta type veth peer name eth0 netns beta")
            machine.succeed("ip link set seter-beta master seter0; bridge link set dev seter-beta isolated on; ip link set seter-beta up")
            machine.succeed("ip -n beta link set lo up; ip -n beta link set eth0 address 02:00:00:00:00:11; ip -n beta link set eth0 up; ip -n beta address add 10.100.0.11/24 dev eth0; ip -n beta route add default via 10.100.0.1")

            # An unregistered, non-isolated bridge port must not create a
            # layer-2 escape path from a registered workspace.
            machine.succeed("ip netns add bridge-peer; ip link add peer-host type veth peer name eth0 netns bridge-peer")
            machine.succeed("ip link set peer-host master seter0; ip link set peer-host up")
            machine.succeed("ip -n bridge-peer link set lo up; ip -n bridge-peer link set eth0 up; ip -n bridge-peer address add 10.100.0.12/24 dev eth0")

            # A routed outside namespace proves that the default deny is not
            # merely an accidental consequence of forwarding being disabled.
            machine.succeed("ip netns add outside; ip link add outside-host type veth peer name eth0 netns outside")
            machine.succeed("ip address add 11.0.0.1/24 dev outside-host; ip link set outside-host up")
            machine.succeed("ip -n outside link set lo up; ip -n outside link set eth0 up; ip -n outside address add 11.0.0.2/24 dev eth0; ip -n outside route add 10.100.0.0/24 via 11.0.0.1")
            machine.succeed("systemd-run --unit=seter-test-upstream --property=Type=simple -- ${pkgs.iproute2}/bin/ip netns exec outside ${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=/dev/null --user=root --port=53 --listen-address=11.0.0.2 --bind-interfaces --no-resolv --no-hosts --address=/allowed.example/11.0.0.2")
            machine.wait_for_unit("seter-test-upstream.service")

            # Workspaces can query the host resolver over UDP and TCP. Only
            # configured egress-name suffixes are forwarded, and IPv6 answers
            # remain hidden while Seter's network boundary is IPv4-only.
            machine.succeed("test $(ip netns exec alpha dig +short @10.100.0.1 allowed.example A) = 11.0.0.2")
            machine.succeed("test $(ip netns exec alpha dig +tcp +short @10.100.0.1 allowed.example A) = 11.0.0.2")
            machine.succeed("test $(ip netns exec alpha dig +short @10.100.0.1 child.allowed.example A) = 11.0.0.2")
            machine.succeed("ip netns exec alpha dig @10.100.0.1 denied.example A | grep -F 'status: NXDOMAIN'")
            machine.succeed("ip netns exec beta dig @10.100.0.1 allowed.example A | grep -F 'status: NXDOMAIN'")
            machine.fail("ip netns exec beta dig +time=1 +tries=1 -p ${toString alphaDnsPort} @10.100.0.1 allowed.example A")
            machine.succeed("alpha_pid=$(systemctl show --value --property MainPID seter-dns-alpha.service); beta_pid=$(systemctl show --value --property MainPID seter-dns-beta.service); test $(awk '/^Uid:/ { print $2 }' /proc/$alpha_pid/status) != $(awk '/^Uid:/ { print $2 }' /proc/$beta_pid/status)")
            machine.succeed("test -z \"$(ip netns exec alpha dig +short @10.100.0.1 allowed.example AAAA)\"")
            machine.succeed("journalctl -u seter-dns-alpha.service | grep -F 'query[A] allowed.example from 10.100.0.10'")
            machine.succeed("getent ahostsv4 alpha.vm | grep -F '10.100.0.10'")
            machine.fail("ip netns exec alpha dig +time=1 +tries=1 @11.0.0.2 allowed.example A")

            # Opening the internal DNS port in the host firewall must not make
            # an unrelated service on another host-local address reachable.
            machine.succeed("systemd-run --unit=seter-test-host-port --property=Type=simple -- ${lib.getExe pkgs.socat} TCP4-LISTEN:${toString alphaDnsPort},bind=11.0.0.1,reuseaddr,fork EXEC:${pkgs.coreutils}/bin/true")
            machine.wait_for_unit("seter-test-host-port.service")
            machine.fail("ip netns exec alpha ${lib.getExe pkgs.netcat} -z -w 1 11.0.0.1 ${toString alphaDnsPort}")

            # A host nftables reload, including a complete ruleset flush, must
            # atomically recreate the Seter tables while workspaces are live.
            machine.succeed("systemctl reload nftables.service")
            machine.succeed("nft list table bridge seter_l2")
            machine.succeed("nft list table inet seter_l3")
            machine.succeed("nft list table inet seter_dns")

            # The host may initiate connections to a workspace. A workspace
            # may not initiate connections to the host, its peers, or routed
            # networks.
            machine.succeed("ping -c 1 -W 1 10.100.0.10")
            machine.succeed("ping -c 1 -W 1 10.100.0.11")
            machine.fail("ip netns exec alpha ping -c 1 -W 1 10.100.0.1")
            machine.fail("ip netns exec alpha ping -c 1 -W 1 10.100.0.11")
            # nftables remains a second lateral boundary if bridge-port
            # isolation is accidentally removed at runtime.
            machine.succeed("bridge link set dev seter-alpha isolated off; bridge link set dev seter-beta isolated off; nft reset counters table bridge seter_l2")
            machine.fail("ip netns exec alpha ping -c 1 -W 1 10.100.0.11")
            machine.succeed("test $(nft --json list chain bridge seter_l2 forward | jq '[.nftables[].rule | select(.comment == \"seter lateral isolation alpha\") | .expr[].counter.packets?] | add // 0') -gt 0; bridge link set dev seter-alpha isolated on; bridge link set dev seter-beta isolated on")

            # The blanket bridge-forward rule also rejects non-workspace ports.
            machine.succeed("nft reset counters table bridge seter_l2")
            machine.fail("ip netns exec alpha ping -c 1 -W 1 10.100.0.12")
            machine.succeed("test $(nft --json list chain bridge seter_l2 forward | jq '[.nftables[].rule | select(.comment == \"seter lateral isolation alpha\") | .expr[].counter.packets?] | add // 0') -gt 0")

            machine.succeed("nft reset counters table inet seter_l3")
            machine.fail("ip netns exec alpha ping -c 1 -W 1 11.0.0.2")
            machine.succeed("test $(nft --json list chain inet seter_l3 forward | jq '[.nftables[].rule | select(.comment == \"seter default-deny alpha\") | .expr[].counter.packets?] | add // 0') -gt 0")

            # Registered IPv4/ARP packets pass the bridge identity chain and
            # are denied later by the host-input chain.
            machine.succeed("nft reset counters table inet seter_l3")
            machine.fail("ip netns exec alpha ping -c 1 -W 1 10.100.0.1")
            machine.succeed("test $(nft --json list chain inet seter_l3 input | jq '[.nftables[].rule | select(.comment == \"seter host isolation alpha\") | .expr[].counter.packets?] | add // 0') -gt 0")

            # A forged IPv4 source is rejected even when ARP is bypassed with a
            # permanent neighbor entry.
            machine.succeed("ip -n alpha address add 10.100.0.99/24 dev eth0; gateway_mac=$(cat /sys/class/net/seter0/address); ip -n alpha neighbor replace 10.100.0.1 lladdr $gateway_mac dev eth0 nud permanent")
            machine.succeed("before=$(nft --json list chain bridge seter_l2 ingress | jq '[.nftables[].rule | select(.comment == \"seter anti-spoof alpha\") | .expr[].counter.packets?] | add // 0'); ip netns exec alpha ping -c 1 -W 1 -I 10.100.0.99 10.100.0.1 || true; after=$(nft --json list chain bridge seter_l2 ingress | jq '[.nftables[].rule | select(.comment == \"seter anti-spoof alpha\") | .expr[].counter.packets?] | add // 0'); test \"$after\" -gt \"$before\"")

            # Forged ARP sender identities are rejected independently.
            machine.succeed("ip -n alpha neighbor del 10.100.0.1 dev eth0; before=$(nft --json list chain bridge seter_l2 ingress | jq '[.nftables[].rule | select(.comment == \"seter anti-spoof alpha\") | .expr[].counter.packets?] | add // 0'); ip netns exec alpha arping -c 1 -w 1 -s 10.100.0.99 -I eth0 10.100.0.1 || true; after=$(nft --json list chain bridge seter_l2 ingress | jq '[.nftables[].rule | select(.comment == \"seter anti-spoof alpha\") | .expr[].counter.packets?] | add // 0'); test \"$after\" -gt \"$before\"")
            machine.succeed("ip -n alpha address del 10.100.0.99/24 dev eth0")

            # The guest cannot adopt another MAC address either.
            machine.succeed("ip -n alpha link set eth0 down; ip -n alpha link set eth0 address 02:00:00:00:00:99; ip -n alpha link set eth0 up")
            machine.succeed("before=$(nft --json list chain bridge seter_l2 ingress | jq '[.nftables[].rule | select(.comment == \"seter anti-spoof alpha\") | .expr[].counter.packets?] | add // 0'); ip netns exec alpha ping -c 1 -W 1 10.100.0.1 || true; after=$(nft --json list chain bridge seter_l2 ingress | jq '[.nftables[].rule | select(.comment == \"seter anti-spoof alpha\") | .expr[].counter.packets?] | add // 0'); test \"$after\" -gt \"$before\"")
            machine.succeed("ip -n alpha link set eth0 down; ip -n alpha link set eth0 address 02:00:00:00:00:10; ip -n alpha link set eth0 up")

            # IPv6 is closed until Seter has an explicit IPv6 policy.
            machine.succeed("ip -6 address add fd00::1/64 dev seter0; ip -n alpha -6 address add fd00::10/64 dev eth0")
            machine.fail("ip netns exec alpha ping -6 -c 1 -W 1 fd00::1")

            machine.succeed("ip netns del alpha; ip netns del beta; ip netns del bridge-peer; ip netns del outside; ip link del seter-alpha 2>/dev/null || true; ip link del seter-beta 2>/dev/null || true")

            # Stopping the required nftables backend tears down active
            # workspace plumbing before its policy tables are removed.
            machine.succeed("systemctl start seter-runtime-alpha.target")
            machine.succeed("ip link show dev seter-alpha")
            machine.succeed("systemctl stop nftables.service")
            machine.wait_until_fails("ip link show dev seter-alpha")
            machine.fail("nft list table bridge seter_l2")
            machine.fail("nft list table inet seter_l3")

            # If the nftables policy cannot load, its dependency prevents a
            # registered TAP from being created.
            machine.succeed("mkdir -p /run/systemd/system/nftables.service.d; printf '[Service]\\nExecStart=\\nExecStart=${pkgs.coreutils}/bin/false\\n' > /run/systemd/system/nftables.service.d/fail.conf; systemctl daemon-reload")
            machine.fail("systemctl start seter-runtime-alpha.target")
            machine.fail("ip link show dev seter-alpha")
            machine.fail("systemctl is-active --quiet seter-dns-alpha.service")
            machine.succeed("rm -rf /run/systemd/system/nftables.service.d; systemctl daemon-reload; systemctl reset-failed nftables.service seter-dns-alpha.service seter-tap-alpha.service seter-virtiofsd-alpha.service seter-runtime-alpha.target")
          '';
        };
      };
    };
}
