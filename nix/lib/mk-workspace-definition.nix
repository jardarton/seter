{
  name,
  runnerInstallable,
  ip,
  mac,
  tap,
  hostname ? "${name}.vm",
  gateway ? "10.100.0.1",
  prefixLength ? 24,
  proxyPort ? 18081,
  memoryMiB ? 4096,
  cpuQuotaPercent ? 200,
  sshUser ? "seter",
  knownHostKey ? null,
  projectImage ? "${name}-project.img",
  allowedHTTPHosts ? [ ],
  passthroughHosts ? [ ],
  allowedTCP ? [ ],
  hostServices ? [ ],
  secrets ? { },
  secretVariables ? { },
  proxyCaCertificate ? null,
}:
let
  guestSecretPlaceholders = builtins.mapAttrs (
    variable: secretName:
    if builtins.hasAttr secretName secrets then
      secrets.${secretName}.placeholder
    else
      throw "seter workspace ${name}: guest secret variable ${variable} references undefined secret ${secretName}"
  ) secretVariables;

  proxyUrl = "http://${gateway}:${toString proxyPort}";
  identity = {
    version = 1;
    workspace = name;
    inherit hostname;
    network = {
      address = ip;
      mac = builtins.toString mac;
      inherit tap gateway prefixLength;
    };
    proxy.url = proxyUrl;
    ssh.user = sshUser;
    storage.image = projectImage;
  };
  identityJson = builtins.toJSON identity;
in
{
  inherit identity identityJson;

  # Host-only projection. In particular, secret source paths and egress policy
  # never become part of the generated guest module below.
  host = {
    runner = {
      installable = runnerInstallable;
      requireIdentity = true;
    };

    inherit hostname hostServices secrets;

    network = {
      address = ip;
      inherit mac tap;
    };

    resources = {
      inherit memoryMiB cpuQuotaPercent;
    };

    ssh = {
      user = sshUser;
      inherit knownHostKey;
    };

    storage.image = projectImage;

    egress = {
      httpHosts = allowedHTTPHosts;
      inherit passthroughHosts;
      tcp = allowedTCP;
    };
  };

  # Sanitized build-time projection. The assertions reject both direct option
  # overrides and drift in the standard lower-level NixOS/microvm wiring. The
  # manifest is still runner-controlled consistency metadata, not attestation;
  # host-side isolation must never trust it as an enforcement boundary.
  guestModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      expected = {
        name = name;
        address = ip;
        mac = lib.toLower mac;
        inherit tap gateway prefixLength;
        proxy = proxyUrl;
        image = projectImage;
        sshUser = sshUser;
      };
      effectiveInterfaceMatches =
        builtins.length config.microvm.interfaces == 1
        && (
          let
            interface = builtins.head config.microvm.interfaces;
          in
          interface.type == "tap" && interface.id == expected.tap && lib.toLower interface.mac == expected.mac
        );
      effectiveNetwork = config.systemd.network.networks."10-seter" or { };
      effectiveNetworkMatches =
        lib.attrByPath [ "matchConfig" "MACAddress" ] null effectiveNetwork != null
        && lib.toLower (lib.attrByPath [ "matchConfig" "MACAddress" ] "" effectiveNetwork) == expected.mac
        && (effectiveNetwork.address or [ ]) == [ "${expected.address}/${toString expected.prefixLength}" ]
        && (effectiveNetwork.routes or [ ]) == [ { Gateway = expected.gateway; } ]
        && lib.attrByPath [ "networkConfig" "DHCP" ] null effectiveNetwork == "no";
      effectiveProjectVolumePresent = lib.any (
        volume:
        (volume.image or null) == expected.image
        && (volume.mountPoint or null) == config.seter.guest.projectDirectory
        && (volume.label or null) == "seter-project"
        && (volume.fsType or null) == "ext4"
      ) config.microvm.volumes;
      baseRunner = config.microvm.runner.${config.microvm.hypervisor};
      identityTree = pkgs.writeTextDir "share/seter/identity.json" identityJson;
      runner = pkgs.symlinkJoin {
        name = "${baseRunner.name}-seter-identity";
        paths = [
          baseRunner
          identityTree
        ];
        postBuild = ''
          # Keep the manifest as a regular immutable store file. The
          # privileged validator deliberately refuses runner-controlled
          # symlinks, devices, FIFOs, and oversized inputs.
          rm -f "$out/share/seter/identity.json"
          cp ${identityTree}/share/seter/identity.json "$out/share/seter/identity.json"
        '';
        inherit (baseRunner) meta;
        passthru = baseRunner.passthru or { };
      };
    in
    {
      seter.guest = {
        enable = true;
        name = name;
        proxy = proxyUrl;
        secretPlaceholders = guestSecretPlaceholders;

        projectVolume.image = projectImage;

        network = {
          enable = true;
          address = ip;
          inherit
            mac
            tap
            gateway
            prefixLength
            ;
          dns = [ gateway ];
        };

        ssh.user = sshUser;
      }
      // lib.optionalAttrs (proxyCaCertificate != null) {
        inherit proxyCaCertificate;
      };

      environment.etc."seter/workspace.json".text = identityJson;
      microvm.declaredRunner = runner;

      assertions = [
        {
          assertion = config.seter.guest.name == expected.name;
          message = "generated Seter workspace identity forbids overriding seter.guest.name";
        }
        {
          assertion = config.seter.guest.network.enable;
          message = "generated Seter workspace identity requires guest networking";
        }
        {
          assertion = config.seter.guest.network.address == expected.address;
          message = "generated Seter workspace identity forbids overriding the guest IPv4 address";
        }
        {
          assertion = lib.toLower config.seter.guest.network.mac == expected.mac;
          message = "generated Seter workspace identity forbids overriding the guest MAC address";
        }
        {
          assertion = config.seter.guest.network.tap == expected.tap;
          message = "generated Seter workspace identity forbids overriding the guest TAP interface";
        }
        {
          assertion = config.seter.guest.network.gateway == expected.gateway;
          message = "generated Seter workspace identity forbids overriding the guest gateway";
        }
        {
          assertion = config.seter.guest.network.prefixLength == expected.prefixLength;
          message = "generated Seter workspace identity forbids overriding the guest prefix length";
        }
        {
          assertion = config.seter.guest.network.dns == [ expected.gateway ];
          message = "generated Seter workspace identity requires the host policy DNS endpoint";
        }
        {
          assertion = effectiveInterfaceMatches;
          message = "generated Seter workspace identity requires exactly its registered microVM TAP interface";
        }
        {
          assertion =
            !config.networking.useDHCP
            && config.networking.useNetworkd
            && config.networking.nameservers == [ expected.gateway ];
          message = "generated Seter workspace identity forbids overriding effective guest network management or DNS";
        }
        {
          assertion = effectiveNetworkMatches;
          message = "generated Seter workspace identity forbids overriding the effective networkd address, route, or MAC match";
        }
        {
          assertion = config.seter.guest.proxy == expected.proxy;
          message = "generated Seter workspace identity forbids overriding the guest proxy endpoint";
        }
        {
          assertion =
            lib.all
              (variable: lib.attrByPath [ variable ] null config.environment.sessionVariables == expected.proxy)
              [
                "HTTP_PROXY"
                "HTTPS_PROXY"
                "http_proxy"
                "https_proxy"
              ];
          message = "generated Seter workspace identity forbids overriding effective guest proxy variables";
        }
        {
          assertion = config.seter.guest.projectVolume.enable;
          message = "generated Seter workspace identity requires the persistent project volume";
        }
        {
          assertion = config.seter.guest.projectVolume.image == expected.image;
          message = "generated Seter workspace identity forbids overriding the project image";
        }
        {
          assertion = effectiveProjectVolumePresent;
          message = "generated Seter workspace identity requires its effective project volume definition";
        }
        {
          assertion = config.seter.guest.ssh.enable && config.services.openssh.enable;
          message = "generated Seter workspace identity requires guest SSH lifecycle access";
        }
        {
          assertion = config.seter.guest.ssh.user == expected.sshUser;
          message = "generated Seter workspace identity forbids overriding the guest SSH user";
        }
        {
          assertion = builtins.hasAttr expected.sshUser config.users.users;
          message = "generated Seter workspace identity requires its effective guest SSH user";
        }
      ]
      ++ lib.mapAttrsToList (variable: placeholder: {
        assertion =
          (config.seter.guest.secretPlaceholders.${variable} or null) == placeholder
          && lib.attrByPath [ variable ] null config.environment.sessionVariables == placeholder;
        message = "generated Seter workspace identity forbids overriding secret placeholder ${variable}";
      }) guestSecretPlaceholders
      ++ lib.optional (proxyCaCertificate != null) {
        assertion =
          config.seter.guest.proxyCaCertificate == proxyCaCertificate
          && builtins.elem proxyCaCertificate config.security.pki.certificates;
        message = "generated Seter workspace identity forbids overriding its proxy CA certificate";
      };
    };
}
