{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.seter.host;
  inherit (lib)
    attrNames
    filterAttrs
    flatten
    mapAttrs'
    mapAttrsToList
    mkIf
    mkOption
    nameValuePair
    types
    unique
    ;

  serviceUnitName = name: "seter-gateway-${name}";
  serviceNames = attrNames cfg.gatewayServices;
  workspaceServiceNames = flatten (
    mapAttrsToList (_: workspace: workspace.hostServices) cfg.workspaces
  );
  activeServices = filterAttrs (
    name: _: builtins.elem name workspaceServiceNames
  ) cfg.gatewayServices;
  activeServiceNames = attrNames activeServices;

  dnsPorts = builtins.attrValues (
    import ./dns-ports.nix {
      inherit lib;
      workspaces = cfg.workspaces;
    }
  );
  serviceValues = builtins.attrValues cfg.gatewayServices;
  listenPorts = map (service: service.listenPort) serviceValues;
  targetAddresses = map (service: service.targetAddress) serviceValues;
  targetPorts = map (service: service.targetPort) serviceValues;

  authorizationsFor =
    serviceName:
    mapAttrsToList (workspaceName: _: workspaceName) (
      filterAttrs (_: workspace: builtins.elem serviceName workspace.hostServices) cfg.workspaces
    );

  authorizationFiles = mapAttrsToList (
    name: _:
    nameValuePair name (
      pkgs.writeText "seter-gateway-${name}-authorizations" (
        lib.concatStringsSep "\n" (authorizationsFor name) + "\n"
      )
    )
  ) activeServices;
  authorizationFileFor = builtins.listToAttrs authorizationFiles;

  gatewaySockets = mapAttrs' (
    name: service:
    nameValuePair (serviceUnitName name) {
      description = "Seter gateway listener for host service ${name}";
      # TAP units hold a Requires= reference while an authorized workspace is
      # active. Once the last such TAP and the idle proxy release the socket,
      # stop listening rather than leaving an effectively permanent service.
      unitConfig.StopWhenUnneeded = true;
      after = [
        "nftables.service"
        "seter-bridge.service"
      ];
      requires = [
        "nftables.service"
        "seter-bridge.service"
      ];
      restartTriggers = [ authorizationFileFor.${name} ];
      listenStreams = [ "${cfg.gateway}:${toString service.listenPort}" ];
      socketConfig = {
        Backlog = 128;
        MaxConnections = 256;
      };
    }
  ) activeServices;

  gatewayServices = mapAttrs' (
    name: service:
    nameValuePair (serviceUnitName name) {
      description = "Seter loopback relay for host service ${name}";
      after = [ "${serviceUnitName name}.socket" ];
      requires = [ "${serviceUnitName name}.socket" ];
      restartTriggers = [ authorizationFileFor.${name} ];
      serviceConfig = {
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --exit-idle-time=5s ${service.targetAddress}:${toString service.targetPort}";
        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectKernelLogs = true;
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
        CapabilityBoundingSet = [ ];
        MemoryMax = 64 * 1024 * 1024;
        TasksMax = 64;
        LimitNOFILE = 1024;
      };
    }
  ) activeServices;
in
{
  options.seter.host.gatewayServices = mkOption {
    type = types.attrsOf (
      types.submodule {
        options = {
          listenPort = mkOption {
            type = types.ints.between 1024 65535;
            description = "TCP port exposed only on the Seter bridge gateway.";
          };

          targetAddress = mkOption {
            type = types.enum [ "127.0.0.1" ];
            default = "127.0.0.1";
            description = ''
              Loopback address of the host daemon. Gateway relays deliberately
              cannot target LAN, workspace, or public addresses because that
              would bypass Seter's egress policy.
            '';
          };

          targetPort = mkOption {
            type = types.ints.between 1 65535;
            description = "Loopback TCP port of the host daemon.";
          };
        };
      }
    );
    default = { };
    description = ''
      Named, host-owned TCP services that may be selectively exposed to
      workspaces through fixed loopback relays on the Seter gateway.
    '';
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (name: builtins.match "[a-z0-9][a-z0-9-]{0,62}" name != null) serviceNames;
        message = "seter.host.gatewayServices names must contain only lower-case letters, digits, and hyphens";
      }
      {
        assertion = builtins.length listenPorts == builtins.length (unique listenPorts);
        message = "seter.host.gatewayServices must use unique listen ports";
      }
      {
        # attrsOf submodules are lazy; force even currently unused service
        # targets through their option types so dormant definitions cannot
        # conceal an unsafe address or invalid port until first authorization.
        assertion = lib.all (address: address == "127.0.0.1") targetAddresses;
        message = "seter.host.gatewayServices may target only 127.0.0.1";
      }
      {
        assertion = lib.all (port: port >= 1 && port <= 65535) targetPorts;
        message = "seter.host.gatewayServices target ports must be valid TCP ports";
      }
      {
        assertion = lib.all (
          port:
          !builtins.elem port [
            cfg.proxy.port
            cfg.proxy.explicitPort
          ]
        ) listenPorts;
        message = "seter.host.gatewayServices listen ports must not collide with Seter proxy ports";
      }
      {
        assertion = lib.all (port: !builtins.elem port dnsPorts) listenPorts;
        message = "seter.host.gatewayServices listen ports must not collide with generated workspace DNS ports";
      }
      {
        assertion = lib.all (name: builtins.elem name serviceNames) workspaceServiceNames;
        message = "seter.host.workspaces hostServices must reference defined seter.host.gatewayServices";
      }
    ];

    systemd.sockets = gatewaySockets;
    systemd.services = gatewayServices;

    # The earlier-priority Seter input chain still restricts each listener to
    # explicitly authorized workspace source addresses. This opening only lets
    # those accepted packets continue through NixOS's native firewall chain.
    networking.firewall.interfaces.${cfg.bridge}.allowedTCPPorts = map (
      name: activeServices.${name}.listenPort
    ) activeServiceNames;
  };
}
