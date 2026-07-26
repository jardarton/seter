{ name, lib, ... }:
let
  inherit (lib) mkOption types;

  hostNameType = types.strMatching "([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9])";
  httpHostType = types.strMatching "([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9])";
  httpHeaderType = types.strMatching "[!#$%&'*+.^_`|~0-9a-zA-Z-]+";
in
{
  options = {
    hostname = mkOption {
      type = hostNameType;
      default = "${name}.vm";
      description = "Host name assigned to the workspace.";
    };

    runner.installable = mkOption {
      type = types.strMatching ".+";
      description = "Nix installable that produces the workspace's microVM runner.";
      example = "github:owner/project#nixosConfigurations.guest.config.microvm.declaredRunner";
    };

    storage.image = mkOption {
      type = types.strMatching "[a-zA-Z0-9_.-]+";
      default = "${name}-project.img";
      description = "Project volume image name inside the workspace state directory.";
    };

    network = {
      address = mkOption {
        type = types.str;
        description = "Static IPv4 address assigned to the workspace.";
        example = "10.100.0.10";
      };

      mac = mkOption {
        type = types.strMatching "[0-9a-fA-F][26aAeE](:[0-9a-fA-F]{2}){5}";
        description = "Unique locally administered unicast MAC address assigned to the workspace.";
        example = "02:00:00:00:00:10";
      };

      tap = mkOption {
        type = types.strMatching "[a-zA-Z0-9_.-]{1,15}";
        description = "Unique host tap interface used by the workspace.";
        example = "seter-project";
      };
    };

    resources = {
      memoryMiB = mkOption {
        type = types.ints.positive;
        default = 4096;
        description = "Maximum workspace memory in MiB.";
      };

      cpuQuotaPercent = mkOption {
        type = types.ints.positive;
        default = 200;
        description = "Workspace systemd CPU quota as a percentage of one CPU.";
      };
    };

    ssh = {
      user = mkOption {
        type = types.strMatching "[a-z_][a-z0-9_-]*";
        default = "seter";
        description = "Unprivileged SSH user in the guest.";
      };

      knownHostKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Pinned SSH host public key. Lifecycle commands must not silently trust an unknown key.";
      };
    };

    hostServices = mkOption {
      type = types.listOf (types.strMatching "[a-z0-9][a-z0-9-]{0,62}");
      default = [ ];
      description = "Named host gateway services this workspace may access.";
    };

    egress = {
      httpHosts = mkOption {
        type = types.listOf httpHostType;
        default = [ ];
        description = "HTTP and HTTPS destination hosts allowed through the policy proxy.";
      };

      passthroughHosts = mkOption {
        type = types.listOf httpHostType;
        default = [ ];
        description = "Allowed HTTPS hosts that bypass TLS interception.";
      };

      tcp = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              host = mkOption {
                type = hostNameType;
                description = "Allowed non-HTTP TCP destination hostname or literal IPv4 address. DNS hostnames are restricted to publicly routed answers.";
              };
              port = mkOption {
                type = types.ints.between 1 65535;
                description = "Allowed non-HTTP TCP destination port.";
              };
            };
          }
        );
        default = [ ];
        description = "Allowed non-HTTP TCP destinations.";
      };
    };

    secrets = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            placeholder = mkOption {
              type = types.str;
              example = "seter-placeholder-github-0123456789abcdef";
              description = "Distinctive non-secret placeholder exposed to the guest.";
            };
            sourceFile = mkOption {
              type = types.strMatching "/.+";
              description = ''
                Runtime path containing the real secret; string-typed so Nix
                does not copy it to the store. The value must contain 8 bytes
                through 16 KiB of ASCII without control characters. One final
                LF or CRLF is removed before validation.
              '';
            };
            hosts = mkOption {
              type = types.nonEmptyListOf httpHostType;
              description = "Intercepted HTTPS destination hosts to which the secret may be sent.";
            };
            headers = mkOption {
              type = types.nonEmptyListOf httpHeaderType;
              description = "HTTP request headers whose values may contain the placeholder.";
            };
          };
        }
      );
      default = { };
      description = "Destination-bound runtime secret definitions. Secret values must never be placed here.";
    };
  };
}
