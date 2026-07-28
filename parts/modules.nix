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
  };
}
