{
  config,
  lib,
  ...
}:
let
  cfg = config.seter.guest;
  inherit (lib)
    attrNames
    attrValues
    concatStringsSep
    intersectLists
    mkEnableOption
    mkIf
    mkOption
    optional
    optionalAttrs
    types
    ;

  proxyEnvironmentNames = [
    "HTTP_PROXY"
    "HTTPS_PROXY"
    "http_proxy"
    "https_proxy"
    "NO_PROXY"
    "no_proxy"
  ];

  nonOverlappingPlaceholders =
    placeholders:
    lib.all (
      placeholder: lib.all (other: placeholder == other || !lib.hasInfix placeholder other) placeholders
    ) placeholders;
in
{
  imports = [
    ./filesystem.nix
    ./microvm.nix
    ./networking.nix
    ./ssh.nix
  ];

  options.seter.guest = {
    enable = mkEnableOption "the Seter project guest conventions";

    name = mkOption {
      type = types.str;
      default = "project";
      description = "Workspace identity used by the host registry.";
    };

    projectDirectory = mkOption {
      type = types.str;
      default = "/project";
      description = "Persistent project working-tree location.";
    };

    proxy = mkOption {
      type = types.nullOr types.str;
      default = if cfg.network.enable then "http://${cfg.network.gateway}:18081" else null;
      defaultText = lib.literalExpression ''
        if seter.guest.network.enable then
          "http://''${seter.guest.network.gateway}:18081"
        else
          null
      '';
      example = "http://10.100.0.1:8080";
      description = ''
        Convenience explicit HTTP proxy URL. This must match the host's
        seter.host.proxy.explicitPort when that option is overridden. Host
        transparent interception remains the enforcement boundary.
      '';
    };

    proxyCaCertificate = mkOption {
      type = types.nullOr types.lines;
      default = null;
      example = lib.literalExpression "builtins.readFile ./seter-proxy-ca-cert.pem";
      description = ''
        PEM certificate for the host's Seter interception CA. Export it with
        `seter proxy-ca`, review it, commit the public certificate with the
        workspace or trusted infra configuration, and set this option so it is
        installed in the guest system trust store. Never put the CA private key
        in a guest or in the Nix store.
      '';
    };

    proxyNoProxy = mkOption {
      type = types.listOf types.str;
      default = [
        "127.0.0.1"
        "localhost"
        "::1"
      ]
      ++ optional cfg.network.enable cfg.network.address;
      description = "Destinations excluded from the convenience explicit proxy variables.";
    };

    secretPlaceholders = mkOption {
      type = types.attrsOf (types.strMatching "seter-placeholder-[a-zA-Z0-9_-]{16,}");
      default = { };
      example = {
        GITHUB_TOKEN = "seter-placeholder-github-0123456789abcdef";
      };
      description = ''
        Non-secret placeholder environment variables exported to guest login
        sessions. Applications send these values in headers configured by the
        matching host-side secret policy, and the host proxy replaces them at
        the network edge. These values are baked into the guest and the Nix
        store; real secret values must never be configured here. Systemd
        services do not inherit session variables and must receive the same
        placeholders explicitly when needed.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.proxyCaCertificate == null
          || (
            lib.hasInfix "-----BEGIN CERTIFICATE-----" cfg.proxyCaCertificate
            && lib.hasInfix "-----END CERTIFICATE-----" cfg.proxyCaCertificate
          );
        message = "seter.guest.proxyCaCertificate must contain a PEM certificate";
      }
      {
        assertion = cfg.proxyCaCertificate == null || !lib.hasInfix "PRIVATE KEY" cfg.proxyCaCertificate;
        message = "seter.guest.proxyCaCertificate must never contain private key material";
      }
      {
        assertion = lib.all (name: builtins.match "[a-zA-Z_][a-zA-Z0-9_]*" name != null) (
          attrNames cfg.secretPlaceholders
        );
        message = "seter.guest.secretPlaceholders names must be valid environment variable names";
      }
      {
        assertion = intersectLists (attrNames cfg.secretPlaceholders) proxyEnvironmentNames == [ ];
        message = "seter.guest.secretPlaceholders must not redefine Seter's proxy environment variables";
      }
      {
        assertion = nonOverlappingPlaceholders (attrValues cfg.secretPlaceholders);
        message = "seter.guest.secretPlaceholders values must not contain one another";
      }
    ];

    environment.etc."vm-guest".text = "seter\n";
    # The root, including /var/log, is ephemeral. Running the default log
    # rotation machinery adds no value and currently leaves a failed
    # logrotate-checkconf unit in this minimal image.
    services.logrotate.enable = lib.mkDefault false;
    security.pki.certificates = optional (cfg.proxyCaCertificate != null) cfg.proxyCaCertificate;
    environment.sessionVariables =
      cfg.secretPlaceholders
      // optionalAttrs (cfg.proxy != null) {
        HTTP_PROXY = cfg.proxy;
        HTTPS_PROXY = cfg.proxy;
        http_proxy = cfg.proxy;
        https_proxy = cfg.proxy;
        NO_PROXY = concatStringsSep "," cfg.proxyNoProxy;
        no_proxy = concatStringsSep "," cfg.proxyNoProxy;
      };
  };
}
