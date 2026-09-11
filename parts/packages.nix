{ inputs, self, ... }:
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

  flake.packages.aarch64-darwin.macos-host =
    let
      pkgs = inputs.nixpkgs.legacyPackages.aarch64-darwin;
    in
    pkgs.writeShellApplication {
      name = "macos-host";
      runtimeInputs = with pkgs; [
        coreutils
        gawk
        gnugrep
        lima
        nixos-rebuild-ng
        openssh
      ];
      text = ''
        export SETER_SOURCE=${self}
        ${builtins.readFile ../scripts/macos-host}
      '';
    };

  flake.apps.aarch64-darwin.macos-host = {
    type = "app";
    program = "${self.packages.aarch64-darwin.macos-host}/bin/macos-host";
    meta.description = "Bootstrap and remotely deploy a Lima Seter Host";
  };
}
