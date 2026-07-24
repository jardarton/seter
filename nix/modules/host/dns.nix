{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.seter.host;
  dnsCfg = cfg.dns;
  inherit (lib)
    concatMap
    concatStringsSep
    mapAttrsToList
    mkIf
    mkOption
    nameValuePair
    optionalString
    types
    unique
    ;

  dnsPorts = import ./dns-ports.nix {
    inherit lib;
    workspaces = cfg.workspaces;
  };
  rawWorkspaces = mapAttrsToList (name: workspace: workspace // { inherit name; }) cfg.workspaces;
  normalizeHosts = map lib.toLower;
  namesFor =
    workspace:
    unique (
      normalizeHosts (
        workspace.egress.httpHosts
        ++ workspace.egress.passthroughHosts
        ++ map (destination: destination.host) workspace.egress.tcp
      )
    );
  workspaces = map (
    workspace:
    workspace
    // {
      dnsPort = dnsPorts.${workspace.name};
      dnsNames = namesFor workspace;
      dnsAccount = "seter-dns-${builtins.substring 0 8 workspace.name}-${
        builtins.substring 0 8 (builtins.hashString "sha256" workspace.name)
      }";
    }
  ) rawWorkspaces;

  upstreamFor =
    name:
    if dnsCfg.upstreamServers == [ ] then
      [ "server=/${name}/#" ]
    else
      map (server: "server=/${name}/${server}") dnsCfg.upstreamServers;

  dnsmasqConfigFor =
    workspace:
    let
      forwardingLines = concatStringsSep "\n" (concatMap upstreamFor workspace.dnsNames);
    in
    pkgs.writeText "seter-dnsmasq-${workspace.name}.conf" ''
      port=${toString workspace.dnsPort}
      interface=${cfg.bridge}
      listen-address=${cfg.gateway}
      bind-interfaces
      no-hosts
      no-dhcp-interface=${cfg.bridge}
      domain-needed
      bogus-priv
      stop-dns-rebind
      filter-AAAA
      local=/#/
      ${optionalString (dnsCfg.upstreamServers != [ ]) "no-resolv"}
      ${forwardingLines}
      ${optionalString dnsCfg.logQueries ''
        log-queries=extra
        log-facility=-
        log-async=25
      ''}
    '';

  dnsmasqConfigs = builtins.listToAttrs (
    map (workspace: nameValuePair workspace.name (dnsmasqConfigFor workspace)) workspaces
  );

  redirectRules = concatStringsSep "\n" (
    concatMap (
      workspace:
      map
        (protocol: ''
          ip daddr ${cfg.gateway} ip saddr ${workspace.network.address} ${protocol} dport 53 redirect to :${toString workspace.dnsPort} comment "seter DNS ${workspace.name}"
        '')
        [
          "udp"
          "tcp"
        ]
    ) workspaces
  );

  dnsServices = builtins.listToAttrs (
    map (
      workspace:
      let
        dnsmasqConfig = dnsmasqConfigs.${workspace.name};
      in
      nameValuePair "seter-dns-${workspace.name}" {
        description = "Seter restricted DNS resolver for workspace ${workspace.name}";
        after = [
          "nftables.service"
          "seter-bridge.service"
        ];
        requires = [
          "nftables.service"
          "seter-bridge.service"
        ];
        partOf = [ "seter-runtime-${workspace.name}.target" ];
        restartTriggers = [ dnsmasqConfig ];
        serviceConfig = {
          Type = "simple";
          User = workspace.dnsAccount;
          Group = workspace.dnsAccount;
          ExecStart = "${lib.getExe pkgs.dnsmasq} --keep-in-foreground --conf-file=${dnsmasqConfig}";
          ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
          Restart = "on-failure";
          RestartSec = "1s";
          CapabilityBoundingSet = [ ];
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectSystem = "strict";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_NETLINK"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
        };
      }
    ) workspaces
  );

  parseIpv4 =
    address:
    let
      rawParts = lib.splitString "." address;
      parsePart =
        part: if builtins.match "(0|[1-9][0-9]{0,2})" part == null then null else lib.toInt part;
      parts = map parsePart rawParts;
    in
    builtins.length parts == 4 && lib.all (part: part != null && part <= 255) parts;
in
{
  options.seter.host.dns = {
    upstreamServers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "192.0.2.53" ];
      description = ''
        Optional IPv4 DNS servers used for configured egress names. An empty
        list uses the host's existing resolvers from /etc/resolv.conf. These
        servers are contacted by the host-side resolver, never directly by a
        workspace.
      '';
    };

    logQueries = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Log workspace DNS queries to its seter-dns-* systemd journal. This is
        an intentionally observable but potentially noisy early policy
        mechanism and may be replaced by more selective audit logging later.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all parseIpv4 dnsCfg.upstreamServers;
        message = "seter.host.dns.upstreamServers must contain valid IPv4 addresses";
      }
      {
        assertion =
          builtins.length workspaces
          == builtins.length (unique (map (workspace: workspace.dnsPort) workspaces));
        message = "seter.host.workspaces generated colliding stable DNS ports; rename one of the colliding workspaces";
      }
      {
        assertion =
          builtins.length workspaces
          == builtins.length (unique (map (workspace: workspace.dnsAccount) workspaces));
        message = "seter.host.workspaces generated colliding DNS service account names";
      }
      {
        assertion = lib.all (workspace: workspace.dnsAccount != cfg.operatorGroup) workspaces;
        message = "seter.host.operatorGroup must not collide with a workspace DNS service account";
      }
    ];

    # Host applications resolve workspace names without replacing the host's
    # resolver or exposing dnsmasq on localhost. The guest-facing resolvers do
    # not publish the complete workspace inventory.
    networking.hosts = builtins.listToAttrs (
      map (workspace: lib.nameValuePair workspace.network.address [ workspace.hostname ]) workspaces
    );

    # Each workspace's port-53 traffic is redirected to a separate unprivileged
    # dnsmasq instance. This preserves per-workspace DNS allowlists without
    # granting the resolver CAP_NET_ADMIN merely to inspect conntrack marks.
    networking.nftables.tables.seter_dns = {
      family = "inet";
      content = ''
        chain dns_redirect {
          type nat hook prerouting priority dstnat; policy accept;
          ${redirectRules}
        }
      '';
    };

    # NAT has translated the destination port by the time the input firewall
    # runs. Open only the generated internal ports on the Seter bridge; Seter's
    # earlier identity-aware chain also binds each port to its workspace IP.
    networking.firewall.interfaces.${cfg.bridge} = {
      allowedTCPPorts = map (workspace: workspace.dnsPort) workspaces;
      allowedUDPPorts = map (workspace: workspace.dnsPort) workspaces;
    };

    users.groups = builtins.listToAttrs (
      map (workspace: nameValuePair workspace.dnsAccount { }) workspaces
    );
    users.users = builtins.listToAttrs (
      map (
        workspace:
        nameValuePair workspace.dnsAccount {
          isSystemUser = true;
          group = workspace.dnsAccount;
          description = "Seter DNS resolver for workspace ${workspace.name}";
        }
      ) workspaces
    );

    systemd.services = dnsServices;
  };
}
