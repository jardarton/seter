{
  inputs,
  self,
  pkgs,
  system,
}:
let
  # RFC 9500 test key. Public test data; never use it for real access.
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

  workspace = {
    repository.url = "https://example.invalid/owner/e2e.git";
    network = {
      address = "10.100.0.20";
      mac = "02:00:00:00:00:20";
      tap = "seter-e2e";
    };
    resources = {
      memoryMiB = 1024;
      cpuQuotaPercent = 200;
    };
    ssh.authorizedKeys = [ testSshPublicKey ];
    storage = {
      project.sizeMiB = 512;
      home.sizeMiB = 512;
      nixStore.sizeMiB = 1024;
    };
  };

  deployment = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.host
      {
        seter.host = {
          enable = true;
          package = seterPackage;
          workspaces.e2e = workspace;
        };
        system.stateVersion = "24.11";
      }
    ];
  };
  runner = deployment.config.environment.etc."seter/runners/e2e".source;
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

      security.sudo.extraRules = [
        {
          users = [ "operator" ];
          runAs = "root";
          commands = [
            {
              command = "${inputs.nixpkgs.lib.getExe seterPackage} __read-host-key e2e";
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];

      virtualisation = {
        memorySize = 4096;
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
    machine.wait_for_unit("seter-proxy.service")
    machine.succeed("test -e /dev/kvm")

    # The registry, lifecycle units, and immutable Runner are one NixOS
    # generation. No project installable or mutable current-runner link exists.
    machine.succeed("test $(readlink -f /etc/seter/runners/e2e) = ${runner}")
    machine.succeed("jq -e '.version == 5 and .workspaces.e2e.guestProfile == \"default\" and .workspaces.e2e.repository.url == \"https://example.invalid/owner/e2e.git\" and .workspaces.e2e.runner.path == \"${runner}\"' /etc/seter/workspaces.json")
    machine.fail("test -e /var/lib/seter/workspaces/e2e/current")
    machine.fail("su - operator -c 'seter update e2e'")

    machine.succeed("install -m 0600 ${testSshPrivateKey} /tmp/seter-e2e-key")
    machine.succeed("install -d -o operator -g users -m 0700 /home/operator/.ssh; install -o operator -g users -m 0600 ${testSshPrivateKey} /home/operator/.ssh/id_ecdsa")
    machine.succeed("su - operator -c 'seter up e2e' | grep -F 'Started e2e at 10.100.0.20'")
    machine.wait_for_unit("seter-vm-e2e.service")
    machine.wait_until_succeeds("ssh-keyscan -T 2 10.100.0.20 > /tmp/e2e-known-hosts 2>/dev/null && test -s /tmp/e2e-known-hosts", timeout=360)

    ssh_options = "-i /tmp/seter-e2e-key -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/e2e-known-hosts -o GlobalKnownHostsFile=/dev/null"
    machine.succeed(f"timeout 60s ssh {ssh_options} seter@10.100.0.20 -- 'test -e /etc/vm-guest && command -v git && command -v direnv && test -e /etc/direnv/direnvrc && test $(findmnt -n -o FSTYPE /nix/store | sort -u) = overlay && printf persistent > /project/runner-model-marker'")

    machine.succeed("su - operator -c 'seter down e2e' | grep -F 'Stopped e2e'")
    machine.wait_until_fails("systemctl is-active --quiet seter-vm-e2e.service")
    machine.succeed("test -s /var/lib/seter/workspaces/e2e/e2e-project.img")
    machine.succeed("test -s /var/lib/seter/workspaces/e2e/e2e-nix-store.img")

    machine.succeed("su - operator -c 'seter ssh-host-key e2e' > /tmp/e2e-host-key 2>/tmp/e2e-fingerprint")
    machine.succeed("grep -E '^ssh-ed25519 ' /tmp/e2e-host-key; grep -F SHA256: /tmp/e2e-fingerprint")
    machine.succeed("jq --rawfile key /tmp/e2e-host-key '.workspaces.e2e.ssh.knownHostKey = ($key | rtrimstr(\"\\n\"))' /etc/seter/workspaces.json > /tmp/registry; rm /etc/seter/workspaces.json; install -m 0644 /tmp/registry /etc/seter/workspaces.json")

    machine.succeed("su - operator -c 'seter up e2e' | grep -F 'Started e2e at 10.100.0.20'")
    machine.wait_for_unit("seter-vm-e2e.service")
    machine.wait_until_succeeds(f"timeout 30s ssh {ssh_options} seter@10.100.0.20 -- 'test $(cat /project/runner-model-marker) = persistent'", timeout=300)
    machine.succeed("printf 'test \"$(cat /project/runner-model-marker)\" = persistent && echo shell-ok\\nexit\\n' | su - operator -c \"timeout 30s script -qec 'seter shell e2e' /dev/null\" | grep -F shell-ok")

    machine.succeed("su - operator -c 'seter down e2e' | grep -F 'Stopped e2e'")
    machine.wait_until_fails("systemctl is-active --quiet seter-runtime-e2e.target")
    machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")
  '';
}
