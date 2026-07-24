{ lib, workspaces }:
let
  firstDynamicPort = 49152;
  dynamicPortCount = 16384;
  portFor =
    name:
    firstDynamicPort
    + lib.mod (lib.fromHexString (
      builtins.substring 0 8 (builtins.hashString "sha256" name)
    )) dynamicPortCount;
in
lib.mapAttrs (name: _: portFor name) workspaces
