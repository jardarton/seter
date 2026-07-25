{
  config,
  lib,
  ...
}:
let
  cfg = config.seter.host;
  inherit (lib)
    concatMapStringsSep
    mapAttrsToList
    mkIf
    ;

  dnsPorts = import ./dns-ports.nix {
    inherit lib;
    workspaces = cfg.workspaces;
  };
  workspaces = mapAttrsToList (
    name: workspace:
    workspace
    // {
      inherit name;
      dnsPort = dnsPorts.${name};
    }
  ) cfg.workspaces;

  bridgeIngressRules = concatMapStringsSep "\n" (
    workspace:
    let
      tap = workspace.network.tap;
      mac = lib.toLower workspace.network.mac;
      address = workspace.network.address;
    in
    ''
      iifname "${tap}" ether saddr ${mac} ether type arp arp saddr ether ${mac} arp saddr ip ${address} accept
      iifname "${tap}" ether saddr ${mac} ether type ip ip saddr ${address} accept
      iifname "${tap}" counter drop comment "seter anti-spoof ${workspace.name}"
    ''
  ) workspaces;

  # Workspace traffic never needs layer-2 forwarding. Host services and routed
  # egress enter the bridge's local stack instead, so reject every forwarded
  # frame rather than relying only on the isolated-port setting.
  bridgeForwardRules = concatMapStringsSep "\n" (
    workspace:
    ''iifname "${workspace.network.tap}" counter drop comment "seter lateral isolation ${workspace.name}"''
  ) workspaces;

  # Once an Ethernet frame enters the bridge's local or routed IP stack, its
  # layer-3 ingress interface is the bridge rather than the TAP. The bridge
  # chain above has already made the source address trustworthy, so layer-3
  # policy can safely identify the workspace by bridge plus source address.
  hostInputRules = concatMapStringsSep "\n" (
    workspace:
    let
      address = workspace.network.address;
    in
    ''
      iifname "${cfg.bridge}" ip saddr ${address} ip daddr ${cfg.gateway} udp dport ${toString workspace.dnsPort} accept comment "seter DNS ${workspace.name}"
      iifname "${cfg.bridge}" ip saddr ${address} ip daddr ${cfg.gateway} tcp dport ${toString workspace.dnsPort} accept comment "seter DNS ${workspace.name}"
      iifname "${cfg.bridge}" ip saddr ${address} ip daddr ${cfg.gateway} meta mark 0x53455450 tcp dport ${toString cfg.proxy.port} accept comment "seter proxy ${workspace.name}"
      iifname "${cfg.bridge}" ip saddr ${address} ct state established,related accept
      iifname "${cfg.bridge}" ip saddr ${address} counter drop comment "seter host isolation ${workspace.name}"
    ''
  ) workspaces;

  forwardRules = concatMapStringsSep "\n" (
    workspace:
    ''iifname "${cfg.bridge}" ip saddr ${workspace.network.address} counter drop comment "seter default-deny ${workspace.name}"''
  ) workspaces;
in
{
  config = mkIf cfg.enable {
    # Seter tables must participate in the host's complete atomic nftables
    # transaction. This deliberately makes the native NixOS nftables backend a
    # host requirement rather than installing out-of-band rules that another
    # nftables reload could silently remove.
    networking.nftables = {
      enable = true;
      tables = {
        seter_l2 = {
          family = "bridge";
          content = ''
            chain ingress {
              type filter hook prerouting priority -10; policy accept;
              ${bridgeIngressRules}
            }

            chain forward {
              type filter hook forward priority -10; policy accept;
              ${bridgeForwardRules}
            }
          '';
        };

        seter_l3 = {
          family = "inet";
          content = ''
            chain input {
              type filter hook input priority -5; policy accept;
              ${hostInputRules}
              iifname "${cfg.bridge}" tcp dport ${toString cfg.proxy.port} counter drop comment "seter direct proxy-port isolation"
            }

            chain forward {
              type filter hook forward priority -5; policy accept;
              ${forwardRules}
            }
          '';
        };
      };
    };
  };
}
