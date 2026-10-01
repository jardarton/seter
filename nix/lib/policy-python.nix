{ pkgs }:
# Copy the files together: Python resolves script symlinks before importing
# siblings, so a link farm would lose the shared module and suffix data.
pkgs.runCommand "seter-policy-python" { } ''
  mkdir -p "$out"
  cp ${../modules/host/dns-policy.py} "$out/dns-policy.py"
  cp ${../modules/host/proxy-addon.py} "$out/proxy-addon.py"
  cp ${../modules/host/host_patterns.py} "$out/host_patterns.py"
  cp ${../modules/host/tcp-egress-refresh.py} "$out/tcp-egress-refresh.py"
  cp ${../../crates/seter-cli/data/public_suffix_list.dat} "$out/public_suffix_list.dat"
''
