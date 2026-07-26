{ inputs, ... }:
{
  flake = {
    nixosModules = {
      host = import ../nix/modules/host;
      guest = {
        imports = [
          inputs.microvm.nixosModules.microvm
          (import ../nix/modules/guest)
        ];
      };
    };

    lib = {
      mkWorkspace = import ../nix/lib/mk-workspace.nix;
      mkWorkspaceDefinition = import ../nix/lib/mk-workspace-definition.nix;
    };
  };
}
