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
  # conservative <=1.1.2 metadata bound. The package imports and runs with
  # 1.2, so bypass only that metadata check until Nixpkgs catches up.
  mitmproxy = pkgs.mitmproxy.overridePythonAttrs (_: {
    dontCheckRuntimeDeps = true;
  });
  proxyAccount = "seter-proxy";
  waitForProxy = pkgs.writeShellScript "seter-proxy-ready" ''
    set -eu
    for attempt in $(${pkgs.coreutils}/bin/seq 1 300); do
      if ${lib.getExe pkgs.netcat} -z -w 1 ${lib.escapeShellArg cfg.gateway} ${toString proxyCfg.port}; then
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

    # The redirect has translated the destination before host-input filtering.
    # The identity-aware Seter chain further restricts this opening to known
    # workspace source addresses and the bridge gateway.
    networking.firewall.interfaces.${cfg.bridge}.allowedTCPPorts = [ proxyCfg.port ];
  };
}
