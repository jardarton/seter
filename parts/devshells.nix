{ inputs, ... }:
let
  mkDevShell =
    pkgs:
    pkgs.mkShell {
      packages = with pkgs; [
        cargo
        clippy
        rustc
        rustfmt
        nixfmt
      ];

      RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
    };
in
{
  perSystem = { pkgs, ... }: {
    devShells.default = mkDevShell pkgs;
  };

  flake.devShells.aarch64-darwin.default = mkDevShell inputs.nixpkgs.legacyPackages.aarch64-darwin;
}
