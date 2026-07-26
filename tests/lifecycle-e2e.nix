{
  inputs,
  self,
  pkgs,
  system,
}:
let
  # RFC 9500 test key. This key is public test data and must never be used for
  # real access: https://www.rfc-editor.org/rfc/rfc9500.html
  testSshPrivateKey = pkgs.writeText "seter-e2e-ssh-key" ''
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIObLW92AqkWunJXowVR2Z5/+yVPBaFHnEedDk5WJxk/BoAoGCCqGSM49
    AwEHoUQDQgAEQiVI+I+3gv+17KN0RFLHKh5Vj71vc75eSOkyMsxFxbFsTNEMTLjV
    uKFxOelIgsiZJXKZNCX0FBmrfpCkKklCcg==
    -----END EC PRIVATE KEY-----
  '';
  testSshPublicKey =
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHA"
    + "yNTYAAABBBEIlSPiPt4L/teyjdERSxyoeVY+9b3O+XkjpMjLMRcWxbEzRDEy41b"
    + "ihcTnpSILImSVymTQl9BQZq36QpCpJQnI= seter-e2e";

  seterPackage = self.packages.${system}.seter;
  seterExecutable = inputs.nixpkgs.lib.getExe seterPackage;

  workspaceDefinition = self.lib.mkWorkspaceDefinition {
    name = "e2e";
    runnerInstallable = "${runner}";
    ip = "10.100.0.20";
    mac = "02:00:00:00:00:20";
    tap = "seter-e2e";
    nixStoreSizeMiB = 1024;
    memoryMiB = 1536;
    cpuQuotaPercent = 200;
    allowedHTTPHosts = [ "11.0.0.2" ];
  };

  mkGuest =
    extraModules:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs; };
      modules = [
        self.nixosModules.guest
        workspaceDefinition.guestModule
        ../examples/minimal/guest.nix
        ({ lib, pkgs, ... }: {
          networking.hostName = lib.mkForce "seter-e2e";
          services.timesyncd.enable = false;
          seter.guest = {
            memory = 1024;
            ssh.authorizedKeys = lib.mkForce [ testSshPublicKey ];
          };
          environment.systemPackages = [ pkgs.util-linux ];
          environment.etc = {
            "seter-test-build.nix".text = ''
              derivation {
                name = "seter-guest-built";
                system = builtins.currentSystem;
                builder = builtins.storePath "${pkgs.runtimeShell}";
                args = [ "-c" "printf guest-built > $out" ];
              }
            '';
            "seter-test-fetch.nix".text = ''
              derivation {
                name = "seter-policy-fetched";
                system = builtins.currentSystem;
                builder = builtins.storePath "${pkgs.runtimeShell}";
                args = [ "-c" "exec 3<>/dev/tcp/11.0.0.2/80; printf 'GET /fetched HTTP/1.0\\r\\nHost: 11.0.0.2\\r\\n\\r\\n' >&3; IFS= read -r status <&3; case \"$status\" in *' 200 '*) ;; *) exit 22;; esac; while IFS= read -r header <&3; do test \"$header\" = \"$(printf '\\r')\" && break; done; IFS= read -r body <&3; printf '%s\\n' \"$body\" > $out" ];
                outputHashMode = "flat";
                outputHashAlgo = "sha256";
                outputHash = "6deae8cd9f3eda38d07a2698828bb1fbf3edf5317785315c66adb6572d7105aa";
              }
            '';
            "seter-test-denied-fetch.nix".text = ''
              derivation {
                name = "seter-policy-denied";
                system = builtins.currentSystem;
                builder = builtins.storePath "${pkgs.runtimeShell}";
                args = [ "-c" "exec 3<>/dev/tcp/11.0.0.3/80; printf 'GET /denied HTTP/1.0\\r\\nHost: 11.0.0.3\\r\\n\\r\\n' >&3; IFS= read -r status <&3; case \"$status\" in *' 200 '*) ;; *) exit 22;; esac; printf 'denied\\n' > $out" ];
                outputHashMode = "flat";
                outputHashAlgo = "sha256";
                outputHash = "ad9c44baa1b750f4391d73516cd9d55019fbf44f552efde461f9965d598d7640";
              }
            '';
          };
        })
      ]
      ++ extraModules;
    };

  guest = mkGuest [ ];
  alternateGuest = mkGuest [ { environment.systemPackages = [ pkgs.hello ]; } ];

  runner = guest.config.microvm.declaredRunner;
  alternateRunner = alternateGuest.config.microvm.declaredRunner;
  workspace = workspaceDefinition.host;
in
pkgs.testers.runNixOSTest {
  name = "seter-lifecycle-e2e";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ self.nixosModules.host ];

      environment.systemPackages = [
        seterPackage
        pkgs.iproute2
        pkgs.jq
        pkgs.openssh
        pkgs.python3
        pkgs.util-linux
      ];

      users.users.operator = {
        isNormalUser = true;
        extraGroups = [ "seter-operators" ];
      };

      seter.host = {
        enable = true;
        package = seterPackage;
        workspaces.e2e = workspace;
      };

      # Update and offline host-key enrollment deliberately remain outside the
      # production operator group's passwordless start/stop grant. Authorize
      # only these exact test invocations so the test exercises their real
      # unprivileged-to-privileged handoff without granting general sudo.
      security.sudo.extraRules = [
        {
          users = [ "operator" ];
          runAs = "root";
          commands = [
            {
              command = "${seterExecutable} __install-runner e2e ${runner}";
              options = [ "NOPASSWD" ];
            }
            {
              command = "${seterExecutable} __install-runner e2e ${alternateRunner}";
              options = [ "NOPASSWD" ];
            }
            {
              command = "${seterExecutable} __read-host-key e2e";
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];

      # This NixOS test VM is itself the Seter host, so it must expose hardware
      # virtualization to the Cloud Hypervisor process running inside it.
      virtualisation = {
        memorySize = 4096;
        cores = 2;
        additionalPaths = [
          runner
          alternateRunner
        ];
        qemu = {
          forceAccel = lib.mkForce true;
          options = [ "-cpu host" ];
        };
      };

      system.stateVersion = "24.11";
    };

  testScript = ''
    start_all()

    machine.wait_for_unit("seter-bridge.service")
    machine.wait_for_unit("seter-proxy.service")
    machine.succeed("test -e /dev/kvm")
    machine.succeed("grep -Eq '(^| )(vmx|svm)( |$)' /proc/cpuinfo")

    # Put the fixed-output test server behind a routed public address. The
    # proxy's second destination boundary deliberately rejects host-local
    # services, so a network namespace exercises the real transparent path.
    machine.succeed("ip netns add seter-upstream; ip link add upstream-host type veth peer name eth0 netns seter-upstream; ip address add 11.0.0.1/24 dev upstream-host; ip link set upstream-host up; ip -n seter-upstream address add 11.0.0.2/24 dev eth0; ip -n seter-upstream link set lo up; ip -n seter-upstream link set eth0 up")
    machine.succeed("mkdir -p /tmp/seter-fetch-upstream; printf 'policy-fetched\\n' > /tmp/seter-fetch-upstream/fetched")
    machine.succeed("systemd-run --unit=seter-test-fetch-upstream --property=Type=simple -- ${pkgs.iproute2}/bin/ip netns exec seter-upstream ${pkgs.python3}/bin/python -m http.server 80 --bind 11.0.0.2 --directory /tmp/seter-fetch-upstream")
    machine.wait_for_unit("seter-test-fetch-upstream.service")

    machine.succeed("install -m 0600 ${testSshPrivateKey} /tmp/seter-e2e-key")
    machine.succeed("install -d -o operator -g users -m 0700 /home/operator/.ssh; install -o operator -g users -m 0600 ${testSshPrivateKey} /home/operator/.ssh/id_ecdsa")
    machine.succeed("su - operator -c 'seter update e2e' | grep -F 'Updated e2e to ${runner}'")
    machine.succeed("test $(readlink /var/lib/seter/workspaces/e2e/current) = ${runner}")
    machine.succeed("test $(readlink /nix/var/nix/gcroots/per-project/.runner-history/e2e/${builtins.baseNameOf runner}) = ${runner}")

    machine.succeed("su - operator -c 'seter up e2e' | grep -F 'Started e2e at 10.100.0.20'")
    machine.wait_for_unit("seter-vm-e2e.service")
    machine.wait_until_succeeds("ssh-keyscan -T 2 10.100.0.20 > /tmp/e2e-known-hosts.new 2>/dev/null && test -s /tmp/e2e-known-hosts.new", timeout=360)
    machine.succeed("mv /tmp/e2e-known-hosts.new /tmp/e2e-known-hosts")
    machine.succeed("seter status e2e | grep -F 'state: running'")

    ssh_options = "-i /tmp/seter-e2e-key -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/e2e-known-hosts -o GlobalKnownHostsFile=/dev/null"
    machine.succeed(f"timeout 180s ssh {ssh_options} seter@10.100.0.20 -- 'test -e /etc/vm-guest && test $(findmnt -n -o FSTYPE /nix/store | sort -u) = overlay && test $(findmnt -n -o FSTYPE /nix | sort -u) = ext4 && test $(readlink -f /nix/var/nix/gcroots/seter-lower-closures/${builtins.baseNameOf guest.config.system.build.toplevel}) = ${guest.config.system.build.toplevel} && printf first-boot > /project/lifecycle-marker && test $(cat /project/lifecycle-marker) = first-boot && nix-build --option substituters \"\" --no-out-link /etc/seter-test-build.nix > /project/nix-output-path && output=$(cat /project/nix-output-path) && test $(cat $output) = guest-built && test ! -e /nix/.ro-store/$(basename $output) && nix-store --query --hash $output > /project/nix-output-hash && nix-store --realise $output --add-root /project/nix-output-root --indirect > /dev/null && nix-build --option substituters \"\" --no-out-link /etc/seter-test-fetch.nix > /project/fetch-output-path && test $(cat $(cat /project/fetch-output-path)) = policy-fetched && ! nix-build --option substituters \"\" --no-out-link /etc/seter-test-denied-fetch.nix'")
    machine.succeed("journalctl -u seter-proxy.service | grep -F '\"host\":\"11.0.0.2\"' | grep -F '\"decision\":\"allow\"'")
    machine.succeed("journalctl -u seter-proxy.service | grep -F '\"host\":\"11.0.0.3\"' | grep -F '\"decision\":\"deny\"'")

    machine.succeed("su - operator -c 'seter down e2e' | grep -F 'Stopped e2e'")
    machine.wait_until_fails("systemctl is-active --quiet seter-vm-e2e.service")
    machine.wait_until_fails("systemctl is-active --quiet seter-runtime-e2e.target")
    machine.wait_until_fails("systemctl is-active --quiet seter-virtiofsd-e2e.service")
    machine.wait_until_fails("ip link show dev seter-e2e")
    machine.wait_until_fails("test -e /run/seter/e2e/virtiofs-ro-store.sock")
    machine.succeed("test ! -e /var/lib/seter/workspaces/e2e/booted")
    machine.succeed("test -s /var/lib/seter/workspaces/e2e/e2e-project.img")
    machine.succeed("test -s /var/lib/seter/workspaces/e2e/e2e-nix-store.img")
    machine.succeed("su - operator -c 'seter ssh-host-key e2e' > /tmp/e2e-host-key 2> /tmp/e2e-host-key-fingerprint")
    machine.succeed("grep -E '^ssh-ed25519 ' /tmp/e2e-host-key")
    machine.succeed("key=$(awk '{ print $1, $2 }' /tmp/e2e-host-key); grep -F \" $key\" /tmp/e2e-known-hosts")
    machine.succeed("grep -F 'SHA256:' /tmp/e2e-host-key-fingerprint")
    machine.succeed("jq --rawfile key /tmp/e2e-host-key '.workspaces.e2e.ssh.knownHostKey = ($key | rtrimstr(\"\\n\"))' /etc/seter/workspaces.json > /tmp/e2e-registry; rm /etc/seter/workspaces.json; install -m 0644 /tmp/e2e-registry /etc/seter/workspaces.json")

    # Boot a distinct system generation against the same private store, then
    # verify destructive guest GC commands are refused. Permanent roots on
    # both sides of the overlay keep the first closure available for rollback.
    machine.succeed("su - operator -c 'sudo -n ${seterExecutable} __install-runner e2e ${alternateRunner}'")
    machine.succeed("test $(readlink /var/lib/seter/workspaces/e2e/current) = ${alternateRunner}")
    machine.succeed("test $(readlink /nix/var/nix/gcroots/per-project/.runner-history/e2e/${builtins.baseNameOf runner}) = ${runner}; test $(readlink /nix/var/nix/gcroots/per-project/.runner-history/e2e/${builtins.baseNameOf alternateRunner}) = ${alternateRunner}")
    machine.succeed("su - operator -c 'seter up e2e' | grep -F 'Started e2e at 10.100.0.20'")
    machine.wait_for_unit("seter-vm-e2e.service")
    machine.wait_until_succeeds(f"timeout 20s ssh {ssh_options} seter@10.100.0.20 -- true", timeout=300)
    machine.succeed(f"timeout 60s ssh {ssh_options} seter@10.100.0.20 -- 'test $(readlink -f /run/booted-system) = ${alternateGuest.config.system.build.toplevel} && test $(readlink -f /nix/var/nix/gcroots/seter-lower-closures/${builtins.baseNameOf guest.config.system.build.toplevel}) = ${guest.config.system.build.toplevel} && test $(readlink -f /nix/var/nix/gcroots/seter-lower-closures/${builtins.baseNameOf alternateGuest.config.system.build.toplevel}) = ${alternateGuest.config.system.build.toplevel} && ! nix-collect-garbage -d && ! nix store gc && ! nix-store --gc && test -e ${guest.config.system.build.toplevel}/init && output=$(cat /project/nix-output-path) && test $(cat $output) = guest-built && test $(nix-store --query --hash $output) = $(cat /project/nix-output-hash) && nix-store --check-validity $output'")
    machine.succeed("printf 'test \"$(cat /project/lifecycle-marker)\" = first-boot && echo shell-ok && printf second-boot > /project/lifecycle-marker\\nexit\\n' | su - operator -c \"timeout 30s script -qec 'seter shell e2e' /dev/null\" | grep -F shell-ok")

    machine.succeed("su - operator -c 'seter down e2e' | grep -F 'Stopped e2e'")
    machine.wait_until_fails("systemctl is-active --quiet seter-vm-e2e.service")
    machine.wait_until_fails("systemctl is-active --quiet seter-runtime-e2e.target")
    machine.wait_until_fails("systemctl is-active --quiet seter-virtiofsd-e2e.service")
    machine.wait_until_fails("ip link show dev seter-e2e")
    machine.wait_until_fails("test -e /run/seter/e2e/virtiofs-ro-store.sock")
    machine.succeed("test ! -e /var/lib/seter/workspaces/e2e/booted")

    machine.succeed("su - operator -c 'sudo -n ${seterExecutable} __install-runner e2e ${runner}'")
    machine.succeed("su - operator -c 'seter up e2e' | grep -F 'Started e2e at 10.100.0.20'")
    machine.wait_for_unit("seter-vm-e2e.service")
    machine.wait_until_succeeds(f"timeout 20s ssh {ssh_options} seter@10.100.0.20 -- true", timeout=300)
    machine.succeed(f"timeout 30s ssh {ssh_options} seter@10.100.0.20 -- 'test $(readlink -f /run/booted-system) = ${guest.config.system.build.toplevel} && test -e ${alternateGuest.config.system.build.toplevel}/init && output=$(cat /project/nix-output-path) && test $(cat $output) = guest-built && nix-store --check-validity $output'")
    machine.succeed("su - operator -c 'seter down e2e' | grep -F 'Stopped e2e'")
    machine.wait_until_fails("systemctl is-active --quiet seter-vm-e2e.service")
    machine.wait_until_fails("systemctl is-active --quiet seter-runtime-e2e.target")
    machine.wait_until_fails("test -e /run/seter/e2e/virtiofs-ro-store.sock")
    machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")
  '';
}
