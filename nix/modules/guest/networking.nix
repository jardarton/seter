{
  config,
  lib,
  ...
}:
let
  cfg = config.seter.guest;
  network = cfg.network;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
in
{
  options.seter.guest.network = {
    enable = mkEnableOption "a static tap network interface";

    tap = mkOption {
      type = types.str;
      default = "seter-${cfg.name}";
      description = "Host tap interface attached to the guest.";
    };

    mac = mkOption {
      type = types.str;
      default = "02:00:00:00:00:01";
      description = "Guest interface MAC address; workspace definitions must assign unique values.";
    };

    address = mkOption {
      type = types.str;
      default = "10.100.0.10";
      description = "Static guest IPv4 address.";
    };

    prefixLength = mkOption {
      type = types.ints.between 0 32;
      default = 24;
      description = "Static guest IPv4 prefix length.";
    };

    gateway = mkOption {
      type = types.str;
      default = "10.100.0.1";
      description = "Guest default IPv4 gateway.";
    };

    dns = mkOption {
      type = types.listOf types.str;
      default = [ network.gateway ];
      description = "DNS servers used by the guest.";
    };
  };

  config = mkIf (cfg.enable && network.enable) {
    networking.useDHCP = false;
    networking.useNetworkd = true;
    networking.nameservers = network.dns;

    microvm.interfaces = [
      {
        type = "tap";
        id = network.tap;
        mac = network.mac;
      }
    ];

    systemd.network.networks."10-seter" = {
      matchConfig.MACAddress = network.mac;
      address = [ "${network.address}/${toString network.prefixLength}" ];
      routes = [ { Gateway = network.gateway; } ];
      networkConfig.DHCP = "no";
    };
  };
}
