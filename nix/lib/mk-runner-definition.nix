{
  name,
  workspace,
  gateway,
  prefixLength,
  proxyPort,
  proxyCaCertificate ? null,
}:
let
  inherit (workspace) hostname secrets secretVariables;
  inherit (workspace.network) mac tap;
  ip = workspace.network.address;
  sshUser = workspace.ssh.user;
  projectImage = workspace.storage.project.image;
  projectSizeMiB = workspace.storage.project.sizeMiB;
  nixStoreImage = workspace.storage.nixStore.image;
  nixStoreSizeMiB = workspace.storage.nixStore.sizeMiB;

  guestSecretPlaceholders = builtins.mapAttrs (
    variable: secretName:
    if builtins.hasAttr secretName secrets then
      secrets.${secretName}.placeholder
    else
      throw "seter workspace ${name}: guest secret variable ${variable} references undefined secret ${secretName}"
  ) secretVariables;

  proxyUrl = "http://${gateway}:${toString proxyPort}";
  identity = {
    version = 2;
    workspace = name;
    inherit hostname;
    network = {
      address = ip;
      mac = builtins.toString mac;
      inherit tap gateway prefixLength;
    };
    proxy.url = proxyUrl;
    ssh.user = sshUser;
    guestProfile = workspace.guestProfile;
    resources.memoryMiB = workspace.resources.memoryMiB;
    storage = workspace.storage;
  };
  identityJson = builtins.toJSON identity;
in
{
  inherit identity identityJson;

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
        inherit projectSizeMiB nixStoreImage nixStoreSizeMiB;
        sshUser = sshUser;
        memoryMiB = workspace.resources.memoryMiB;
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
        && (volume.size or null) == expected.projectSizeMiB
      ) config.microvm.volumes;
      effectiveNixStoreVolumePresent = lib.any (
        volume:
        (volume.image or null) == expected.nixStoreImage
        && (volume.mountPoint or null) == "/nix"
        && (volume.label or null) == "seter-nix"
        && (volume.fsType or null) == "ext4"
        && (volume.size or null) == expected.nixStoreSizeMiB
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

        projectVolume = {
          image = projectImage;
          size = projectSizeMiB;
        };

        nixStore = {
          enable = true;
          image = nixStoreImage;
          size = nixStoreSizeMiB;
        };

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
          assertion = config.seter.guest.projectVolume.size == expected.projectSizeMiB;
          message = "generated Seter workspace identity forbids overriding the project volume size";
        }
        {
          assertion = effectiveProjectVolumePresent;
          message = "generated Seter workspace identity requires its effective project volume definition";
        }
        {
          assertion = config.seter.guest.nixStore.enable;
          message = "generated Seter workspace identity requires a private writable Nix store";
        }
        {
          assertion = config.seter.guest.nixStore.image == expected.nixStoreImage;
          message = "generated Seter workspace identity forbids overriding the private Nix store image";
        }
        {
          assertion = config.seter.guest.nixStore.size == expected.nixStoreSizeMiB;
          message = "generated Seter workspace identity forbids overriding the private Nix store size";
        }
        {
          assertion = effectiveNixStoreVolumePresent;
          message = "generated Seter workspace identity requires its effective private Nix store volume";
        }
        {
          assertion =
            config.microvm.writableStoreOverlay == "/nix/.rw-store"
            && lib.attrByPath [ "/nix" "neededForBoot" ] false config.fileSystems;
          message = "generated Seter workspace identity requires the persistent /nix writable-store overlay";
        }
        {
          assertion =
            config.nix.settings.sandbox
            && !config.nix.settings.auto-optimise-store
            && lib.attrByPath [ "min-free" ] null config.nix.settings == 0
            && lib.attrByPath [ "max-free" ] null config.nix.settings == 0
            && lib.attrByPath [ "gc-reserved-space" ] null config.nix.settings == 0
            && !config.nix.optimise.automatic
            && !config.nix.gc.automatic;
          message = "generated Seter workspace identity requires sandboxed Nix builds with overlay-safe optimisation and garbage-collection settings";
        }
        {
          assertion =
            config.seter.guest.memory == expected.memoryMiB && config.microvm.mem == expected.memoryMiB;
          message = "generated Seter workspace identity forbids overriding the guest memory recorded in its manifest";
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
