{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      seter = pkgs.callPackage ../nix/package.nix { };
    in
    {
      packages = {
        inherit seter;
        default = seter;
      };

      apps.default = {
        type = "app";
        program = pkgs.lib.getExe seter;
        meta.description = "Manage isolated, Nix-managed project VMs";
      };
    };
}
