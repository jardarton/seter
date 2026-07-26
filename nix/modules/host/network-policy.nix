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
  tcpSets = import ./tcp-egress-sets.nix {
    inherit lib;
    workspaces = cfg.workspaces;
  };
  workspaces = mapAttrsToList (
    name: workspace:
    workspace
    // {
      inherit name;
      dnsPort = dnsPorts.${name};
      tcpSet = tcpSets.${name};
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

  tcpWorkspaces = lib.filter (workspace: workspace.egress.tcp != [ ]) workspaces;
  hasTcpEgress = tcpWorkspaces != [ ];
  tcpSetDeclarations = concatMapStringsSep "\n" (workspace: ''
    set ${workspace.tcpSet} {
      type ipv4_addr . inet_service
      comment "Seter direct TCP destinations for ${workspace.name}"
    }
  '') tcpWorkspaces;

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
      hostServiceRules = concatMapStringsSep "\n" (
        serviceName:
        let
          service = cfg.gatewayServices.${serviceName};
        in
        ''iifname "${cfg.bridge}" ip saddr ${address} ip daddr ${cfg.gateway} tcp dport ${toString service.listenPort} counter accept comment "seter host service ${workspace.name} ${serviceName}"''
      ) workspace.hostServices;
    in
    ''
      iifname "${cfg.bridge}" ip saddr ${address} ip daddr ${cfg.gateway} udp dport ${toString workspace.dnsPort} accept comment "seter DNS ${workspace.name}"
      iifname "${cfg.bridge}" ip saddr ${address} ip daddr ${cfg.gateway} tcp dport ${toString workspace.dnsPort} accept comment "seter DNS ${workspace.name}"
      iifname "${cfg.bridge}" ip saddr ${address} ip daddr ${cfg.gateway} meta mark 0x53455450 tcp dport ${toString cfg.proxy.port} accept comment "seter proxy ${workspace.name}"
      iifname "${cfg.bridge}" ip saddr ${address} ip daddr ${cfg.gateway} tcp dport ${toString cfg.proxy.explicitPort} accept comment "seter explicit proxy ${workspace.name}"
      ${hostServiceRules}
      iifname "${cfg.bridge}" ip saddr ${address} ct state established,related accept
      iifname "${cfg.bridge}" ip saddr ${address} counter drop comment "seter host isolation ${workspace.name}"
    ''
  ) workspaces;

  forwardRules = concatMapStringsSep "\n" (workspace: ''
    ${lib.optionalString (workspace.egress.tcp != [ ])
      ''iifname "${cfg.bridge}" ip saddr ${workspace.network.address} ip daddr . tcp dport @${workspace.tcpSet} accept comment "seter direct TCP ${workspace.name}"''
    }
    iifname "${cfg.bridge}" ip saddr ${workspace.network.address} counter drop comment "seter default-deny ${workspace.name}"
  '') workspaces;
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
              ibrname "${cfg.bridge}" counter drop comment "seter unregistered bridge ingress"
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
            ${tcpSetDeclarations}

            chain input {
              type filter hook input priority -5; policy accept;
              ${hostInputRules}
              iifname "${cfg.bridge}" counter drop comment "seter unregistered host isolation"
            }

            chain forward {
              type filter hook forward priority -5; policy accept;
              ${forwardRules}
              iifname "${cfg.bridge}" counter drop comment "seter unregistered routed isolation"
            }
          '';
        };
      }
      // lib.optionalAttrs hasTcpEgress {
        seter_tcp_nat = {
          family = "ip";
          content = ''
            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;
              ip saddr { ${
                lib.concatStringsSep ", " (map (workspace: workspace.network.address) tcpWorkspaces)
              } } counter masquerade comment "seter direct TCP egress"
            }
          '';
        };
      };
    };

    # Seter's earlier-priority chain drops every unauthorized bridge packet.
    # Let authorized direct-TCP connections continue through NixOS's native
    # forward firewall, whose separate base chain would otherwise drop them.
    networking.firewall.extraForwardRules = lib.mkIf hasTcpEgress ''
      iifname "${cfg.bridge}" ip saddr { ${
        lib.concatStringsSep ", " (map (workspace: workspace.network.address) tcpWorkspaces)
      } } accept comment "Seter authorized egress"
    '';
    networking.firewall.filterForward = lib.mkIf hasTcpEgress (lib.mkDefault true);

    # Routed egress requires the kernel's global forwarding switch. Requiring
    # NixOS's forwarding firewall keeps that host-wide switch from making
    # unrelated interfaces routable; the rule above opens only traffic that
    # has already passed Seter's earlier destination policy.
    boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkIf hasTcpEgress (lib.mkOverride 99 1);

    assertions = [
      {
        assertion =
          !hasTcpEgress || (config.networking.firewall.enable && config.networking.firewall.filterForward);
        message = "seter direct TCP egress requires networking.firewall.enable and networking.firewall.filterForward so enabling IPv4 forwarding cannot expose unrelated host interfaces";
      }
    ];
  };
}
