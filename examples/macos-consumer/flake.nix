{
  description = "Minimal consumer-owned Seter Host for Lima";

  inputs = {
    # Use the nixpkgs revision against which this Seter revision is tested.
    nixpkgs.follows = "seter/nixpkgs";
    seter = {
      url = "github:jardarton/seter";
    };
  };

  outputs =
    { nixpkgs, seter, ... }:
    {
      nixosConfigurations.seter-host = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          seter.nixosModules.limaHost
          ./host.nix
        ];
      };
    };
}
