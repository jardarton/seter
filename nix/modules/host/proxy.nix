{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.seter.host;
  proxyCfg = cfg.proxy;
  inherit (lib)
    mkIf
    mkOption
    nameValuePair
    types
    unique
    ;

  normalizeHosts = hosts: unique (map lib.toLower hosts);
  policy = {
    version = 1;
    workspaces = builtins.listToAttrs (
      lib.mapAttrsToList (
        name: workspace:
        nameValuePair workspace.network.address {
          inherit name;
          httpHosts = normalizeHosts workspace.egress.httpHosts;
          passthroughHosts = normalizeHosts workspace.egress.passthroughHosts;
        }
      ) cfg.workspaces
    );
  };
  policyFile = pkgs.writeText "seter-proxy-policy.json" (builtins.toJSON policy);
  addon = ./proxy-addon.py;
  # The pinned Nixpkgs currently carries msgpack 1.2 with mitmproxy's
  # conservative <=1.1.2 metadata bound. Relax only that dependency until
  # Nixpkgs catches up, preserving checks for every other runtime dependency.
  mitmproxy = pkgs.mitmproxy.overridePythonAttrs (old: {
    pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "msgpack" ];
  });
  proxyAccount = "seter-proxy";
  waitForProxy = pkgs.writeShellScript "seter-proxy-ready" ''
    set -eu
    for attempt in $(${pkgs.coreutils}/bin/seq 1 300); do
      if ! kill -0 "$MAINPID" 2>/dev/null; then
        echo "Seter proxy exited before becoming ready" >&2
        exit 1
      fi
      if ${pkgs.iproute2}/bin/ss --no-header --listening --numeric --tcp \
        'sport = :${toString proxyCfg.port}' \
        | ${pkgs.gnugrep}/bin/grep -Fq ${lib.escapeShellArg "${cfg.gateway}:${toString proxyCfg.port}"}; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 0.1
    done
    echo "Seter proxy did not become ready on ${cfg.gateway}:${toString proxyCfg.port}" >&2
    exit 1
  '';
in
{
  options.seter.host.proxy = {
    uid = mkOption {
      type = types.ints.between 1 65533;
      default = 60534;
      description = ''
        Fixed host UID for the Seter proxy account. The UID identifies proxy
        output packets to nftables and must not be used by another account.
      '';
    };

    port = mkOption {
      type = types.ints.between 1024 49151;
      default = 18080;
      description = ''
        Internal host port used by Seter's transparent HTTP and HTTPS policy
        proxy. Workspace traffic cannot select this port directly.
      '';
    };

    logRequests = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Log structured policy decisions for workspace HTTP requests and TLS
        connections to the proxy service journal.
      '';
    };

    upstreamCaFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional PEM CA bundle used to verify HTTPS upstream servers instead
        of the proxy package's default trust roots.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.operatorGroup != proxyAccount;
        message = "seter.host.operatorGroup must not collide with the Seter proxy service account";
      }
    ]
    ++ lib.mapAttrsToList (name: workspace: {
      assertion =
        lib.intersectLists (normalizeHosts workspace.egress.httpHosts) (
          normalizeHosts workspace.egress.passthroughHosts
        ) == [ ];
      message = "seter.host.workspaces.${name} must not list a host for both HTTP interception and TLS passthrough";
    }) cfg.workspaces;

    users.groups.${proxyAccount} = { };
    users.users.${proxyAccount} = {
      isSystemUser = true;
      group = proxyAccount;
      uid = proxyCfg.uid;
      description = "Seter HTTP policy proxy";
    };

    systemd.services.seter-proxy = {
      description = "Seter transparent HTTP and HTTPS policy proxy";
      wantedBy = [ "multi-user.target" ];
      after = [
        "nftables.service"
        "seter-bridge.service"
      ];
      requires = [
        "nftables.service"
        "seter-bridge.service"
      ];
      restartTriggers = [ policyFile ];
      serviceConfig = {
        Type = "simple";
        User = proxyAccount;
        Group = proxyAccount;
        StateDirectory = "seter-proxy";
        StateDirectoryMode = "0700";
        Environment = "PYTHONUNBUFFERED=1";
        ExecStart = ''
          ${lib.getExe' mitmproxy "mitmdump"} \
            --mode transparent \
            --listen-host ${cfg.gateway} \
            --listen-port ${toString proxyCfg.port} \
            --scripts ${addon} \
            --set confdir=/var/lib/seter-proxy \
            --set connection_strategy=lazy \
            --set upstream_cert=false \
            --set rawtcp=false \
            --set flow_detail=0 \
            --set termlog_verbosity=info \
            --set seter_policy=${policyFile} \
            --set seter_log_requests=${if proxyCfg.logRequests then "true" else "false"}${
              lib.optionalString (
                proxyCfg.upstreamCaFile != null
              ) " \\\n            --set ssl_verify_upstream_trusted_ca=${proxyCfg.upstreamCaFile}"
            }
        '';
        ExecStartPost = waitForProxy;
        Restart = "on-failure";
        RestartSec = "1s";
        MemoryMax = 512 * 1024 * 1024;
        TasksMax = 256;
        LimitNOFILE = 8192;
        LogRateLimitIntervalSec = "1s";
        LogRateLimitBurst = 1000;
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

    networking.nftables.tables.seter_proxy = {
      family = "inet";
      content = ''
        chain proxy_redirect {
          type nat hook prerouting priority dstnat; policy accept;
          ${lib.concatMapStringsSep "\n" (workspace: ''
            iifname "${cfg.bridge}" ip saddr ${workspace.network.address} tcp dport { 80, 443 } meta mark set 0x53455450 redirect to :${toString proxyCfg.port} comment "seter proxy ${workspace.name}"
          '') (lib.mapAttrsToList (name: workspace: workspace // { inherit name; }) cfg.workspaces)}
        }
      '';
    };

    # Hostname checks in the addon are the primary destination policy. Keep a
    # second boundary on the proxy account itself so a parser bug cannot turn
    # the unprivileged service into a path to host or private-network services.
    # DNS is the only private-address exception required by getaddrinfo.
    networking.nftables.tables.seter_proxy_output = {
      family = "inet";
      content = ''
        chain proxy_output {
          type filter hook output priority -5; policy accept;
          meta skuid ${toString proxyCfg.uid} udp dport 53 accept
          meta skuid ${toString proxyCfg.uid} tcp dport 53 accept
          meta skuid ${toString proxyCfg.uid} ip saddr ${cfg.gateway} tcp sport ${toString proxyCfg.port} ct state established accept
          meta skuid ${toString proxyCfg.uid} fib daddr type { local, broadcast, multicast } counter reject comment "seter proxy local destination"
          meta skuid ${toString proxyCfg.uid} ip daddr {
            0.0.0.0/8,
            10.0.0.0/8,
            100.64.0.0/10,
            127.0.0.0/8,
            169.254.0.0/16,
            172.16.0.0/12,
            192.0.0.0/24,
            192.0.2.0/24,
            192.168.0.0/16,
            198.18.0.0/15,
            198.51.100.0/24,
            203.0.113.0/24,
            224.0.0.0/4,
            240.0.0.0/4
          } counter reject comment "seter proxy non-public destination"
          meta skuid ${toString proxyCfg.uid} ip daddr ${cfg.subnet} counter reject comment "seter proxy workspace destination"
        }
      '';
    };

    # The redirect has translated the destination before host-input filtering.
    # The identity-aware Seter chain further restricts this opening to known
    # workspace source addresses and the bridge gateway.
    networking.firewall.interfaces.${cfg.bridge}.allowedTCPPorts = [ proxyCfg.port ];
  };
}
