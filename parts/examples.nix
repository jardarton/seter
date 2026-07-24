{
  inputs,
  self,
  ...
}:
let
  mkMinimal =
    extraModules:
    inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        self.nixosModules.guest
        ../examples/minimal/guest.nix
      ]
      ++ extraModules;
    };
in
{
  flake.nixosConfigurations = {
    minimal = mkMinimal [ ];
    minimal-test = mkMinimal [ ../examples/minimal/verification.nix ];
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
            for expected in marker root-tmpfs project-writable store-read-only ssh-active ssh-host-key-persistent; do
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
