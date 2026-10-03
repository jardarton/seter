{
  devFlake,
  system,
  shellName ? "default",
}:
let
  shell =
    devFlake.devShells.${system}.${shellName}
      or (throw "seter.lib.devShellSeeds: development flake has no devShells.${system}.${shellName}");
  bash = devFlake.inputs.nixpkgs.legacyPackages.${system}.bashInteractive;
in
[ shell ]
++ (
  if devFlake ? inputs.nixpkgs then
    [
      bash.out
      bash.man
    ]
  else
    [ ]
)
