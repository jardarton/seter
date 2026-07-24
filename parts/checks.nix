{ inputs, self, ... }: {
  perSystem = { pkgs, system, ... }: {
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
              system.stateVersion = "24.11";
              fileSystems."/" = {
                device = "/dev/vda";
                fsType = "ext4";
              };
              boot.loader.grub.devices = [ "nodev" ];
            }
          ];
        }).config.system.build.toplevel;
    };
  };
}
