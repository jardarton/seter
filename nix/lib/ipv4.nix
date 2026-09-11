{ lib }:
address:
let
  rawParts = lib.splitString "." address;
  parsePart =
    part: if builtins.match "(0|[1-9][0-9]{0,2})" part == null then null else lib.toInt part;
  parts = map parsePart rawParts;
  valid = builtins.length parts == 4 && lib.all (part: part != null && part <= 255) parts;
in
if valid then lib.foldl' (value: part: value * 256 + part) 0 parts else null
