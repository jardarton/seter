{ inputs, self, ... }:
{
  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    {
      checks = {
        inherit (self.packages.${system}) seter;

        nixos-host-module =
          (inputs.nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.host
              {
                system.stateVersion = "24.11";
                fileSystems."/" = {
                  device = "/dev/vda";
                  fsType = "ext4";
                };
                boot.loader.grub.devices = [ "nodev" ];
              }
            ];
          }).config.system.build.toplevel;

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
