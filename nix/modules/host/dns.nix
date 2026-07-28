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

  parseIpv4 =
    address:
    let
      rawParts = lib.splitString "." address;
      parsePart =
        part: if builtins.match "(0|[1-9][0-9]{0,2})" part == null then null else lib.toInt part;
      parts = map parsePart rawParts;
    in
    builtins.length parts == 4 && lib.all (part: part != null && part <= 255) parts;

  normalizeHosts = map lib.toLower;
  repositoryHostFor =
    workspace:
    lib.toLower (
      builtins.elemAt (builtins.match "https://([^/:]+)(:443)?(/.*)" workspace.repository.url) 0
    );
  namesFor =
    workspace:
    unique (
      lib.filter (name: !parseIpv4 name) (
        normalizeHosts (
          [ (repositoryHostFor workspace) ]
          ++ workspace.egress.httpHosts
          ++ workspace.egress.passthroughHosts
          ++ map (destination: destination.host) workspace.egress.tcp
        )
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

  upstreamAccount = "seter-dns-upstream";
  dnsPython = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.dnspython ]);
  dnsPolicyProgram = ./dns-policy.py;

  upstreamConfig = pkgs.writeText "seter-dns-upstream.conf" ''
    port=${toString dnsCfg.upstreamPort}
    interface=lo
    listen-address=127.0.0.1
    bind-interfaces
    no-hosts
    no-dhcp-interface=lo
    bogus-priv
    stop-dns-rebind
    filter-AAAA
    cache-size=1000
    dns-forward-max=${toString (lib.max 150 (builtins.length workspaces * dnsCfg.maxConcurrentQueries))}
    ${optionalString (dnsCfg.upstreamServers != [ ]) ''
      no-resolv
      ${concatStringsSep "\n" (map (server: "server=${server}") dnsCfg.upstreamServers)}
    ''}
  '';

  policyFileFor =
    workspace:
    pkgs.writeText "seter-dns-policy-${workspace.name}.json" (
      builtins.toJSON {
        version = 1;
        workspace = workspace.name;
        sourceAddress = workspace.network.address;
        allowedNames = workspace.dnsNames;
        backendAddress = "127.0.0.1";
        backendPort = dnsCfg.upstreamPort;
        inherit (dnsCfg)
          logQueries
          maxConcurrentQueries
          queriesPerSecond
          queryBurst
          upstreamTimeoutSeconds
          ;
      }
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
        policyFile = policyFileFor workspace;
      in
      nameValuePair "seter-dns-${workspace.name}" {
        description = "Seter strict DNS policy for workspace ${workspace.name}";
        after = [
          "nftables.service"
          "seter-bridge.service"
          "seter-dns-upstream.service"
        ];
        requires = [
          "nftables.service"
          "seter-bridge.service"
          "seter-dns-upstream.service"
        ];
        partOf = [ "seter-runtime-${workspace.name}.target" ];
        restartTriggers = [ policyFile ];
        serviceConfig = {
          Type = "exec";
          User = workspace.dnsAccount;
          Group = workspace.dnsAccount;
          ExecStart = ''
            ${dnsPython}/bin/python ${dnsPolicyProgram} \
              --config ${policyFile} \
              --listen-address ${cfg.gateway} \
              --listen-port ${toString workspace.dnsPort}
          '';
          Restart = "on-failure";
          RestartSec = "1s";
          MemoryMax = 128 * 1024 * 1024;
          TasksMax = 64;
          LimitNOFILE = 512;
          LogRateLimitIntervalSec = "1s";
          LogRateLimitBurst = 250;
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
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          SystemCallArchitectures = "native";
        };
      }
    ) workspaces
  );
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
        servers are contacted by the host-side caching resolver, never
        directly by a workspace.
      '';
    };

    upstreamPort = mkOption {
      type = types.ints.between 1024 49151;
      default = 15353;
      description = ''
        Loopback-only port for Seter's shared caching DNS backend. Workspaces
        cannot connect to this listener directly.
      '';
    };

    upstreamTimeoutSeconds = mkOption {
      type = types.numbers.between 0.1 60.0;
      default = 3.0;
      description = "Timeout for a policy resolver request to the local caching backend.";
    };

    maxConcurrentQueries = mkOption {
      type = types.ints.between 1 4096;
      default = 64;
      description = "Maximum concurrent DNS requests handled for one workspace.";
    };

    queriesPerSecond = mkOption {
      type = types.ints.between 1 1000000;
      default = 200;
      description = "Sustained DNS query rate allowed for one workspace.";
    };

    queryBurst = mkOption {
      type = types.ints.between 1 1000000;
      default = 400;
      description = "Maximum per-workspace DNS query burst before requests are refused.";
    };

    logQueries = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Log structured allow and deny decisions to each seter-dns-* systemd
        journal. Names and query types are logged, but raw packets and EDNS
        data are never included.
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
        assertion = dnsCfg.queryBurst >= dnsCfg.queriesPerSecond;
        message = "seter.host.dns.queryBurst must be at least seter.host.dns.queriesPerSecond";
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
      {
        assertion = upstreamAccount != cfg.operatorGroup;
        message = "seter.host.operatorGroup must not collide with the Seter DNS backend account";
      }
    ];

    # Host applications resolve workspace names without replacing the host's
    # resolver. Guest-facing policy listeners do not publish the workspace
    # inventory.
    networking.hosts = builtins.listToAttrs (
      map (workspace: lib.nameValuePair workspace.network.address [ workspace.hostname ]) workspaces
    );

    # Every port-53 request addressed to the gateway is redirected to that
    # source workspace's private policy listener. The listener then rebuilds
    # exact, approved A requests before using the loopback caching backend.
    networking.nftables.tables.seter_dns = {
      family = "inet";
      content = ''
        chain dns_redirect {
          type nat hook prerouting priority dstnat; policy accept;
          ${redirectRules}
        }
      '';
    };

    # NAT has translated the destination before host-input filtering. Open
    # only generated internal ports on the Seter bridge; the earlier
    # identity-aware chain additionally binds each port to one workspace IP.
    networking.firewall.interfaces.${cfg.bridge} = {
      allowedTCPPorts = map (workspace: workspace.dnsPort) workspaces;
      allowedUDPPorts = map (workspace: workspace.dnsPort) workspaces;
    };

    users.groups =
      builtins.listToAttrs (map (workspace: nameValuePair workspace.dnsAccount { }) workspaces)
      // lib.optionalAttrs (workspaces != [ ]) { ${upstreamAccount} = { }; };
    users.users =
      builtins.listToAttrs (
        map (
          workspace:
          nameValuePair workspace.dnsAccount {
            isSystemUser = true;
            group = workspace.dnsAccount;
            description = "Seter DNS policy resolver for workspace ${workspace.name}";
          }
        ) workspaces
      )
      // lib.optionalAttrs (workspaces != [ ]) {
        ${upstreamAccount} = {
          isSystemUser = true;
          group = upstreamAccount;
          description = "Seter shared caching DNS backend";
        };
      };

    systemd.services =
      dnsServices
      // lib.optionalAttrs (workspaces != [ ]) {
        seter-dns-upstream = {
          description = "Seter loopback caching DNS backend";
          after = [ "network.target" ];
          unitConfig.StopWhenUnneeded = true;
          restartTriggers = [ upstreamConfig ];
          serviceConfig = {
            Type = "exec";
            User = upstreamAccount;
            Group = upstreamAccount;
            ExecStart = "${lib.getExe pkgs.dnsmasq} --keep-in-foreground --conf-file=${upstreamConfig}";
            Restart = "on-failure";
            RestartSec = "1s";
            MemoryMax = 128 * 1024 * 1024;
            TasksMax = 32;
            LimitNOFILE = 512;
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
            SystemCallArchitectures = "native";
          };
        };
      };
  };
}
