{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.seter.guest;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
in
{
  options.seter.guest = {
    enable = mkEnableOption "the Seter project guest conventions";

    name = mkOption {
      type = types.str;
      default = "project";
      description = "Workspace identity used by the host registry.";
    };

    projectDirectory = mkOption {
      type = types.str;
      default = "/project";
      description = "Persistent project working-tree location.";
    };

    proxy = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "http://10.100.0.1:8080";
      description = "Convenience HTTP proxy URL; host enforcement must not rely on this setting.";
    };
  };

  config = mkIf cfg.enable {
    environment.etc."vm-guest".text = "seter\n";
    environment.sessionVariables = mkIf (cfg.proxy != null) {
      HTTP_PROXY = cfg.proxy;
      HTTPS_PROXY = cfg.proxy;
      http_proxy = cfg.proxy;
      https_proxy = cfg.proxy;
    };
    environment.systemPackages = [ pkgs.git ];
  };
}
