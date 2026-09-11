{ inputs, ... }:
{
  flake.nixosModules = {
    host = {
      imports = [ (import ../nix/modules/host) ];
      _module.args.seterMicrovmModule = inputs.microvm.nixosModules.microvm;
    };

    guest = {
      imports = [
        inputs.microvm.nixosModules.microvm
        (import ../nix/modules/guest)
      ];
    };

    limaHost = {
      imports = [
        inputs.nixos-lima.nixosModules.lima
        (import ../nix/modules/host)
        (import ../nix/modules/lima-host.nix)
      ];
      _module.args.seterMicrovmModule = inputs.microvm.nixosModules.microvm;
    };
  };
}
