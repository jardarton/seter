{ lib, workspaces }:
lib.mapAttrs (
  name: _: "tcp_${builtins.substring 0 16 (builtins.hashString "sha256" name)}"
) workspaces
