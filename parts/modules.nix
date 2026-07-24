{ ... }: {
  flake = {
    nixosModules = {
      host = import ../nix/modules/host;
      guest = import ../nix/modules/guest;
    };

    lib.mkWorkspace = import ../nix/lib/mk-workspace.nix;
  };
}
