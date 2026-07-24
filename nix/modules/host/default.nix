{
  config,
  lib,
  ...
}:
let
  cfg = config.seter.host;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
in
{
  options.seter.host = {
    enable = mkEnableOption "the Seter micro-VM host";

    bridge = mkOption {
      type = types.str;
      default = "seter0";
      description = "Network bridge used by project VMs.";
    };

    subnet = mkOption {
      type = types.str;
      default = "10.100.0.0/24";
      description = "IPv4 subnet assigned to project VMs.";
    };

    workspaces = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = "Workspace registry. Its stable schema will be tightened as the implementation develops.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.bridge != "";
        message = "seter.host.bridge must not be empty";
      }
    ];

    # Host networking, DNS, proxy, and lifecycle services will be added here.
  };
}
