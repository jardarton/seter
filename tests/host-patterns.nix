{ pkgs }:
let
  lib = pkgs.lib;
  patterns = import ../nix/modules/host/host-patterns.nix { inherit lib; };
  casesFile = ../crates/seter-cli/data/host-pattern-cases.json;
  cases = builtins.fromJSON (builtins.readFile casesFile);
  policyPython = import ../nix/lib/policy-python.nix { inherit pkgs; };
  python = pkgs.python3.withPackages (ps: [
    ps.dnspython
    (ps.mitmproxy.overridePythonAttrs (old: {
      pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "msgpack" ];
    }))
  ]);
in
assert lib.all (
  case:
  lib.assertMsg (
    patterns.exactValid case.input == case.exact
    && patterns.valid case.input == case.pattern
    && (!case.pattern || lib.toLower case.input == case.canonical)
  ) "Host Pattern contract mismatch: ${case.label}"
) cases.hosts;
assert lib.all (
  case:
  lib.assertMsg (
    patterns.matches case.pattern case.host == case.matches
  ) "Host Pattern match mismatch: ${case.pattern} / ${case.host}"
) cases.matches;
assert lib.all (
  case:
  lib.assertMsg (
    patterns.overlaps case.left case.right == case.overlaps
  ) "Host Pattern overlap mismatch: ${case.left} / ${case.right}"
) cases.overlaps;
pkgs.runCommand "seter-host-patterns-check" { } ''
  ${python}/bin/python ${policyPython}/dns-policy.py --help > /dev/null
  ${python}/bin/python ${policyPython}/tcp-egress-refresh.py --help > /dev/null
  PYTHONPATH=${policyPython} ${python}/bin/python ${./host-patterns.py} ${policyPython} ${casesFile}
  touch "$out"
''
