{
  config,
  lib,
  ...
}:
let
  cfg = config.seter.host;
  cacheCfg = cfg.nixCache;
  inherit (lib)
    mkIf
    mkOption
    types
    ;
in
{
  options.seter.host.nixCache = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Serve the host Nix store read-only to workspaces as a binary cache.
        Guests substitute already-present host paths instead of rebuilding or
        downloading them. The cache never builds or evaluates anything, so
        workspace requests cannot execute code on the host. Every workspace
        using the cache can read the whole host store, so secrets must never
        enter it.
      '';
    };

    listenPort = mkOption {
      type = types.ints.between 1024 65535;
      default = 5000;
      description = "TCP port of the cache relay on the Seter bridge gateway.";
    };

    localPort = mkOption {
      type = types.ints.between 1024 65535;
      default = 5000;
      description = "Loopback TCP port on which the Seter-managed Harmonia cache listens.";
    };
  };

  config = mkIf (cfg.enable && cacheCfg.enable) {
    # Harmonia only serves existing valid paths; it has no build endpoint.
    # Bind it to loopback and reach it through Seter's authorized gateway
    # relay, never directly on the bridge or a LAN interface.
    services.harmonia.cache = {
      enable = true;
      settings.bind = "127.0.0.1:${toString cacheCfg.localPort}";
    };

    seter.host.gatewayServices.nix-cache = {
      inherit (cacheCfg) listenPort;
      targetPort = cacheCfg.localPort;
    };
  };
}
