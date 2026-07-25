{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.seter.host;
  tcpCfg = cfg.tcpEgress;
  inherit (lib)
    mapAttrs'
    mkIf
    mkOption
    nameValuePair
    types
    ;

  tcpSets = import ./tcp-egress-sets.nix {
    inherit lib;
    workspaces = cfg.workspaces;
  };
  refreshProgram = pkgs.writeTextFile {
    name = "seter-tcp-egress-refresh";
    executable = true;
    text = builtins.replaceStrings [ "#!/usr/bin/env python3" ] [ "#!${pkgs.python3}/bin/python3" ] (
      builtins.readFile ./tcp-egress-refresh.py
    );
  };
  workspacesWithTcp = lib.filterAttrs (_: workspace: workspace.egress.tcp != [ ]) cfg.workspaces;

  serviceName = name: "seter-tcp-egress-${name}";
  refreshCommand =
    name: configFile:
    "${refreshProgram} --config ${configFile} --dig ${pkgs.bind.dnsutils}/bin/dig --nft ${lib.getExe pkgs.nftables} --set ${tcpSets.${name}}";

  tcpServices = mapAttrs' (
    name: workspace:
    let
      configFile = pkgs.writeText "seter-tcp-egress-${name}.json" (
        builtins.toJSON {
          destinations = workspace.egress.tcp;
          upstreamServers = cfg.dns.upstreamServers;
        }
      );
      refresh = refreshCommand name configFile;
      run = pkgs.writeShellScript "seter-tcp-egress-${name}-run" ''
        set -eu
        while ${pkgs.coreutils}/bin/sleep ${toString tcpCfg.refreshIntervalSeconds}; do
          ${refresh}
        done
      '';
      flush = pkgs.writeShellScript "seter-tcp-egress-${name}-flush" ''
        ${refresh} --flush 2>/dev/null || true
      '';
    in
    nameValuePair (serviceName name) {
      description = "Seter direct TCP destination resolver for workspace ${name}";
      after = [
        "network-online.target"
        "nftables.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "nftables.service" ];
      partOf = [ "seter-runtime-${name}.target" ];
      restartTriggers = [ configFile ];
      serviceConfig = {
        Type = "exec";
        ExecStartPre = refresh;
        ExecStart = run;
        ExecReload = refresh;
        ExecStopPost = flush;
        Restart = "on-failure";
        RestartSec = "1s";
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
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
  ) workspacesWithTcp;
in
{
  options.seter.host.tcpEgress.refreshIntervalSeconds = mkOption {
    type = types.ints.positive;
    default = 30;
    description = ''
      Interval at which direct-TCP hostnames are re-resolved into their
      workspace-specific nftables destination sets. Set updates are atomic;
      failed or filtered resolutions remove the corresponding authorization.
    '';
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion =
          builtins.length (builtins.attrValues tcpSets)
          == builtins.length (lib.unique (builtins.attrValues tcpSets));
        message = "seter.host.workspaces generated colliding direct-TCP nftables set names";
      }
    ]
    ++ lib.mapAttrsToList (name: workspace: {
      assertion = lib.all (
        destination:
        !builtins.elem destination.port [
          80
          443
        ]
      ) workspace.egress.tcp;
      message = "seter.host.workspaces.${name}.egress.tcp must not use ports 80 or 443; those ports are always enforced by the HTTP policy proxy";
    }) cfg.workspaces;

    systemd.services = tcpServices // {
      # A managed nftables reload recreates the dynamic sets. Propagate that
      # reload so active workspace services immediately repopulate them rather
      # than waiting for the periodic refresh.
      nftables.unitConfig.PropagatesReloadTo = map (name: "${serviceName name}.service") (
        builtins.attrNames workspacesWithTcp
      );
    };
  };
}
