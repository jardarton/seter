{ name, lib, ... }:
let
  inherit (lib) mkOption types;

  hostNameType = types.strMatching "([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9])";
  httpHostType = types.strMatching "([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9])";
  httpHeaderType = types.strMatching "[!#$%&'*+.^_`|~0-9a-zA-Z-]+";
  imageNameType = types.strMatching "[a-zA-Z0-9_.-]+";
in
{
  options = {
    repository = {
      url = mkOption {
        type = types.strMatching "https://[a-zA-Z0-9.-]+(:[0-9]+)?/[^?#[:space:]]+";
        description = "Approved HTTPS Git repository URL for this workspace.";
        example = "https://git.example/owner/project.git";
      };

      branch = mkOption {
        type = types.nullOr (types.strMatching "[^[:space:]]+");
        default = null;
        description = "Optional initial branch; null uses the remote default branch.";
      };

      checkoutName = mkOption {
        type = types.nullOr (types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_.-]*");
        default = null;
        description = "Optional checkout directory override. By default it is derived from the repository URL.";
      };

      credential = mkOption {
        type = types.nullOr (types.strMatching "[a-zA-Z][a-zA-Z0-9_-]{0,62}");
        default = null;
        description = "Optional name of the repository credential binding in this workspace's secrets.";
      };
    };

    guestProfile = mkOption {
      type = types.enum [ "default" ];
      default = "default";
      description = "Trusted Guest Profile used to build the host-deployed Runner.";
    };

    hostname = mkOption {
      type = hostNameType;
      default = "${name}.vm";
      description = "Host name assigned to the workspace.";
    };

    storage = {
      project = {
        image = mkOption {
          type = imageNameType;
          default = "${name}-project.img";
          description = "Project Volume image name inside the workspace state directory.";
        };
        sizeMiB = mkOption {
          type = types.ints.positive;
          default = 4096;
          description = "Initial Project Volume capacity in MiB.";
        };
      };

      home = {
        image = mkOption {
          type = imageNameType;
          default = "${name}-home.img";
          description = "Home Volume image name inside the workspace state directory.";
        };
        sizeMiB = mkOption {
          type = types.ints.positive;
          default = 4096;
          description = "Initial Home Volume capacity in MiB.";
        };
      };

      nixStore = {
        image = mkOption {
          type = imageNameType;
          default = "${name}-nix-store.img";
          description = "Private persistent Nix-store volume image name inside the workspace state directory.";
        };
        sizeMiB = mkOption {
          type = types.ints.positive;
          default = 16384;
          description = "Initial private Nix-store volume capacity in MiB.";
        };
      };
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
        description = "Workspace guest memory in MiB.";
      };
      hostOverheadMiB = mkOption {
        type = types.ints.positive;
        default = 512;
        description = ''
          Host memory allowed for the VMM process on top of the guest's RAM.
          The workspace's systemd MemoryMax is the sum of the two. That limit
          is a backstop against a runaway VMM, not the guest's memory budget:
          virtiofs forces cloud-hypervisor to back guest RAM with a shared
          memfd, so those pages are charged to the workspace slice and cannot
          be reclaimed without swap. Sizing the limit to the guest's RAM alone
          therefore guarantees an OOM kill once the guest has faulted in every
          page.
        '';
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
      authorizedKeys = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Trusted public keys authorized for workspace login.";
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
                description = "Allowed non-HTTP TCP destination hostname or literal IPv4 address.";
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

    secretVariables = mkOption {
      type = types.attrsOf (types.strMatching "[a-zA-Z][a-zA-Z0-9_-]{0,62}");
      default = { };
      description = "Guest environment variables mapped to named non-secret credential placeholders.";
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
              description = "Runtime path containing the real secret; it must not be a Nix store path.";
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
      description = "Destination-bound runtime credential bindings. Secret values must never be placed here.";
    };
  };
}
