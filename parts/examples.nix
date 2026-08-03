{
  inputs,
  self,
  ...
}:
let
  minimalWorkspace = {
    hostname = "minimal.vm";
    guestProfile = "default";
    repository = {
      url = "https://example.invalid/owner/minimal.git";
      branch = null;
      checkoutName = null;
      credential = null;
    };
    network = {
      address = "10.100.0.10";
      mac = "02:00:00:00:00:10";
      tap = "seter-minimal";
    };
    resources = {
      memoryMiB = 2048;
      vcpu = 2;
      cpuQuotaPercent = 200;
    };
    ssh = {
      user = "seter";
      authorizedKeys = [ ];
    };
    storage = {
      project = {
        image = "minimal-project.img";
        sizeMiB = 512;
      };
      home = {
        image = "minimal-home.img";
        sizeMiB = 4096;
      };
      nixStore = {
        image = "minimal-nix-store.img";
        sizeMiB = 1024;
      };
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

  minimalDefinition = import ../nix/lib/mk-runner-definition.nix {
    name = "minimal";
    workspace = minimalWorkspace;
    gateway = "10.100.0.1";
    prefixLength = 24;
    proxyPort = 18081;
  };

  mkMinimal =
    identityModules: extraModules:
    inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        self.nixosModules.guest
        ../nix/modules/guest/profiles/default.nix
      ]
      ++ identityModules
      ++ [ ../examples/minimal/guest.nix ]
      ++ extraModules;
    };
in
{
  flake.nixosConfigurations = {
    minimal =
      mkMinimal
        [
          minimalDefinition.guestModule
          # The host module supplies these from the same registry entry. Set them
          # explicitly here so the example does not silently depend on the guest
          # defaults happening to match the registered resources.
          { seter.guest.memory = minimalWorkspace.resources.memoryMiB; }
        ]
        [ ];
    # The standalone boot verification deliberately has no host TAP. Keep it
    # identity-less so it can disable networking and use a disposable image.
    minimal-test =
      mkMinimal
        [
          {
            seter.guest = {
              enable = true;
              name = "minimal";
            };
          }
        ]
        [ ../examples/minimal/verification.nix ];
  };

  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        runner = self.nixosConfigurations.minimal-test.config.microvm.declaredRunner;
        minimal-test = pkgs.writeShellApplication {
          name = "seter-test-minimal";
          runtimeInputs = [
            runner
            pkgs.coreutils
            pkgs.e2fsprogs
            pkgs.gnugrep
            pkgs.openssh
            pkgs.virtiofsd
          ];
          text = ''
            set -eu
            work=$(mktemp -d)
            virtiofsd_pid=
            stop_virtiofsd() {
              if test -n "$virtiofsd_pid"; then
                kill "$virtiofsd_pid" 2>/dev/null || true
                wait "$virtiofsd_pid" 2>/dev/null || true
                virtiofsd_pid=
              fi
            }
            cleanup() {
              stop_virtiofsd
              rm -rf "$work"
            }
            trap cleanup EXIT
            cd "$work"

            socket=seter-minimal-virtiofs-ro-store.sock
            start_virtiofsd() {
              rm -f "$socket"
              virtiofsd \
                --socket-path="$socket" \
                --shared-dir=/nix/store \
                --readonly \
                > virtiofsd.log 2>&1 &
              virtiofsd_pid=$!

              for _ in $(seq 1 100); do
                test -S "$socket" && return
                sleep 0.1
              done
              test -S "$socket"
            }

            start_virtiofsd
            timeout 120 microvm-run
            stop_virtiofsd
            debugfs -R 'cat /.seter-state/ssh/ssh_host_ed25519_key.pub' test-project.img > host-key-first.pub

            start_virtiofsd
            timeout 120 microvm-run
            stop_virtiofsd
            debugfs -R 'cat /.seter-state/ssh/ssh_host_ed25519_key.pub' test-project.img > host-key-second.pub
            cmp host-key-first.pub host-key-second.pub
            ssh-keygen -l -f host-key-second.pub

            debugfs -R 'cat /seter-verification' test-project.img > report
            test -s minimal-nix-store.img
            for expected in marker root-tmpfs project-writable store-overlay store-lower-read-only nix-state-persistent ssh-active ssh-host-key-persistent; do
              grep -Fx "$expected" report
            done

            echo "Seter minimal VM verification passed"
          '';
        };
      in
      {
        packages.minimal-test = minimal-test;
        apps.test-minimal = {
          type = "app";
          program = lib.getExe minimal-test;
          meta.description = "Boot and verify the minimal Seter microVM";
        };
      }
    );
}
