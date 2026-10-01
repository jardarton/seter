{ lib }:
let
  label = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?";
  exactPattern = "${label}(\\.${label})+";
  publicSuffixRules = builtins.listToAttrs (
    map (rule: lib.nameValuePair rule true) (
      lib.filter (line: line != "" && !(lib.hasPrefix "//" line)) (
        map lib.trim (
          lib.splitString "\n" (builtins.readFile ../../../crates/seter-cli/data/public_suffix_list.dat)
        )
      )
    )
  );
  hasPublicSuffixRule = rule: builtins.hasAttr rule publicSuffixRules;
  labels = value: lib.splitString "." value;
  wildcardSuffixForbidden =
    suffix:
    let
      parts = labels suffix;
      parent = lib.concatStringsSep "." (lib.drop 1 parts);
      exception = hasPublicSuffixRule "!${suffix}";
    in
    builtins.length parts < 2
    || lib.any (lib.hasPrefix "xn--") parts
    || (
      !exception
      && (
        hasPublicSuffixRule suffix || hasPublicSuffixRule "*.${suffix}" || hasPublicSuffixRule "*.${parent}"
      )
    );
  parseIpv4 = import ../../lib/ipv4.nix { inherit lib; };
  numeric = host: builtins.match "[0-9.]+" host != null;
  exactValid =
    host:
    builtins.stringLength host <= 253
    && builtins.match exactPattern (lib.toLower host) != null
    && (!numeric host || parseIpv4 host != null);
  valid =
    pattern:
    let
      normalized = lib.toLower pattern;
    in
    if lib.hasPrefix "*." normalized then
      let
        suffix = lib.removePrefix "*." normalized;
      in
      builtins.stringLength normalized <= 253
      && exactValid suffix
      && !numeric suffix
      && !wildcardSuffixForbidden suffix
    else
      exactValid normalized && !(lib.hasInfix "*" normalized);
  wildcardMatches =
    pattern: exact:
    if !lib.hasPrefix "*." pattern then
      false
    else
      let
        suffix = lib.removePrefix "*." pattern;
        ending = ".${suffix}";
        prefix = lib.removeSuffix ending exact;
      in
      lib.hasSuffix ending exact && prefix != "" && !(lib.hasInfix "." prefix);
  overlaps =
    left: right: lib.toLower left == lib.toLower right || matches left right || matches right left;
  matches =
    pattern: host:
    exactValid host
    && (
      lib.toLower pattern == lib.toLower host || wildcardMatches (lib.toLower pattern) (lib.toLower host)
    );
in
{
  inherit
    exactValid
    matches
    overlaps
    valid
    wildcardSuffixForbidden
    ;
}
