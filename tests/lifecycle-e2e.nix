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

  guest = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = { inherit inputs; };
    modules = [
      self.nixosModules.guest
      ../examples/minimal/guest.nix
      ({ lib, ... }: {
        networking.hostName = lib.mkForce "seter-e2e";
        seter.guest = {
          name = lib.mkForce "e2e";
          memory = 768;
          projectVolume.image = lib.mkForce "e2e-project.img";
          network = {
            tap = lib.mkForce "seter-e2e";
            mac = lib.mkForce "02:00:00:00:00:20";
            address = lib.mkForce "10.100.0.20";
          };
          ssh.authorizedKeys = lib.mkForce [ testSshPublicKey ];
        };
      })
    ];
  };

  runner = guest.config.microvm.declaredRunner;
  workspace = self.lib.mkWorkspace {
    runnerInstallable = "${runner}";
    ip = "10.100.0.20";
    mac = "02:00:00:00:00:20";
    tap = "seter-e2e";
    memoryMiB = 1536;
    cpuQuotaPercent = 200;
  };
in
pkgs.testers.runNixOSTest {
  name = "seter-lifecycle-e2e";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ self.nixosModules.host ];

      environment.systemPackages = [
        seterPackage
        pkgs.jq
        pkgs.openssh
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
              command = "${seterExecutable} __read-host-key e2e";
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];

      # This NixOS test VM is itself the Seter host, so it must expose hardware
      # virtualization to the Cloud Hypervisor process running inside it.
      virtualisation = {
        memorySize = 3072;
        cores = 2;
        additionalPaths = [ runner ];
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
    machine.succeed("test -e /dev/kvm")
    machine.succeed("grep -Eq '(^| )(vmx|svm)( |$)' /proc/cpuinfo")

    machine.succeed("install -m 0600 ${testSshPrivateKey} /tmp/seter-e2e-key")
    machine.succeed("install -d -o operator -g users -m 0700 /home/operator/.ssh; install -o operator -g users -m 0600 ${testSshPrivateKey} /home/operator/.ssh/id_ecdsa")
    machine.succeed("su - operator -c 'seter update e2e' | grep -F 'Updated e2e to ${runner}'")
    machine.succeed("test $(readlink /var/lib/seter/workspaces/e2e/current) = ${runner}")

    machine.succeed("su - operator -c 'seter up e2e' | grep -F 'Started e2e at 10.100.0.20'")
    machine.wait_for_unit("seter-vm-e2e.service")
    machine.wait_until_succeeds("ssh-keyscan -T 2 10.100.0.20 > /tmp/e2e-known-hosts.new 2>/dev/null && test -s /tmp/e2e-known-hosts.new", timeout=180)
    machine.succeed("mv /tmp/e2e-known-hosts.new /tmp/e2e-known-hosts")
    machine.succeed("seter status e2e | grep -F 'state: running'")

    ssh_options = "-i /tmp/seter-e2e-key -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/e2e-known-hosts -o GlobalKnownHostsFile=/dev/null"
    machine.wait_until_succeeds(f"timeout 20s ssh {ssh_options} seter@10.100.0.20 -- 'test -e /etc/vm-guest && printf first-boot > /project/lifecycle-marker && test $(cat /project/lifecycle-marker) = first-boot'", timeout=180)

    machine.succeed("su - operator -c 'seter down e2e' | grep -F 'Stopped e2e'")
    machine.wait_until_fails("systemctl is-active --quiet seter-vm-e2e.service")
    machine.wait_until_fails("systemctl is-active --quiet seter-runtime-e2e.target")
    machine.wait_until_fails("systemctl is-active --quiet seter-virtiofsd-e2e.service")
    machine.wait_until_fails("ip link show dev seter-e2e")
    machine.wait_until_fails("test -e /run/seter/e2e/virtiofs-ro-store.sock")
    machine.succeed("test ! -e /var/lib/seter/workspaces/e2e/booted")
    machine.succeed("test -s /var/lib/seter/workspaces/e2e/e2e-project.img")
    machine.succeed("su - operator -c 'seter ssh-host-key e2e' > /tmp/e2e-host-key 2> /tmp/e2e-host-key-fingerprint")
    machine.succeed("grep -E '^ssh-ed25519 ' /tmp/e2e-host-key")
    machine.succeed("key=$(awk '{ print $1, $2 }' /tmp/e2e-host-key); grep -F \" $key\" /tmp/e2e-known-hosts")
    machine.succeed("grep -F 'SHA256:' /tmp/e2e-host-key-fingerprint")
    machine.succeed("jq --rawfile key /tmp/e2e-host-key '.workspaces.e2e.ssh.knownHostKey = ($key | rtrimstr(\"\\n\"))' /etc/seter/workspaces.json > /tmp/e2e-registry; rm /etc/seter/workspaces.json; install -m 0644 /tmp/e2e-registry /etc/seter/workspaces.json")

    machine.succeed("su - operator -c 'seter up e2e' | grep -F 'Started e2e at 10.100.0.20'")
    machine.wait_for_unit("seter-vm-e2e.service")
    machine.wait_until_succeeds(f"timeout 20s ssh {ssh_options} seter@10.100.0.20 -- true", timeout=180)
    machine.succeed("printf 'test \"$(cat /project/lifecycle-marker)\" = first-boot && echo shell-ok && printf second-boot > /project/lifecycle-marker\\nexit\\n' | su - operator -c \"timeout 30s script -qec 'seter shell e2e' /dev/null\" | grep -F shell-ok")

    machine.succeed("su - operator -c 'seter down e2e' | grep -F 'Stopped e2e'")
    machine.wait_until_fails("systemctl is-active --quiet seter-vm-e2e.service")
    machine.wait_until_fails("systemctl is-active --quiet seter-runtime-e2e.target")
    machine.wait_until_fails("systemctl is-active --quiet seter-virtiofsd-e2e.service")
    machine.wait_until_fails("ip link show dev seter-e2e")
    machine.wait_until_fails("test -e /run/seter/e2e/virtiofs-ro-store.sock")
    machine.succeed("test ! -e /var/lib/seter/workspaces/e2e/booted")
    machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")
  '';
}
