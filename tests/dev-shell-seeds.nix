{
  self,
  pkgs,
  system,
}:
let
  devShellSeeds = self.lib.devShellSeeds;
  defaultShell = pkgs.mkShell { packages = [ pkgs.hello ]; };
  namedShell = pkgs.mkShell { packages = [ pkgs.git ]; };
  # Distinct from the caller's Bash: companions must use the development pin.
  pinnedBash = pkgs.bashInteractive.overrideAttrs { pname = "seed-fixture-bash"; };
  devFlake = {
    devShells.${system} = {
      default = defaultShell;
      tools = namedShell;
    };
    inputs.nixpkgs.legacyPackages.${system}.bashInteractive = pinnedBash;
  };
  withoutNixpkgs = { inherit (devFlake) devShells; };
in
assert
  devShellSeeds { inherit devFlake system; } == [
    defaultShell
    pinnedBash.out
    pinnedBash.man
  ];
assert
  devShellSeeds {
    inherit devFlake system;
    shellName = "tools";
  } == [
    namedShell
    pinnedBash.out
    pinnedBash.man
  ];
assert
  devShellSeeds {
    devFlake = withoutNixpkgs;
    inherit system;
  } == [ defaultShell ];
assert
  devShellSeeds {
    devFlake = withoutNixpkgs // {
      inputs = { };
    };
    inherit system;
  } == [ defaultShell ];
assert
  !(builtins.tryEval (
    builtins.deepSeq (devShellSeeds {
      inherit devFlake system;
      shellName = "missing";
    }) true
  )).success;
pkgs.runCommand "seter-dev-shell-seeds-check" { } ''
  touch "$out"
''
