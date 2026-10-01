{
  inputs,
  self,
  pkgs,
  system,
  fixtures,
}:
let
  inherit (fixtures)
    mkTestWorkspace
    hostModuleBase
    mkHostWith
    mkHost
    validWorkspaces
    identityGuestConfiguration
    ;
  # Force every option value the seter modules define, stopping at
  # derivations so evaluation does not descend into their build graph.
  forceOptions =
    value:
    if lib.isDerivation value then
      true
    else if builtins.isAttrs value then
      lib.all forceOptions (builtins.attrValues value)
    else if builtins.isList value then
      lib.all forceOptions value
    else
      builtins.seq value true;

  # Rejections come from two places: module assertions, and option type
  # checks such as the bounds on dns.upstreamTimeoutSeconds. Forcing both
  # is what makes this equivalent to building system.build.toplevel, at
  # roughly half the evaluation cost.
  forceConfiguration =
    configuration:
    builtins.tryEval (
      builtins.seq (forceOptions configuration.config.seter) (
        builtins.deepSeq (map (
          entry: if entry.assertion then true else throw entry.message
        ) configuration.config.assertions) true
      )
    );

  configurationRejected = workspaces: !(forceConfiguration (mkHost workspaces)).success;

  hostConfigurationRejected = host: !(forceConfiguration (mkHostWith host)).success;

  # Exercise credential validation with an authorized HTTP destination,
  # so a missing egress grant cannot mask the intended rejection.
  httpPolicyFileFor =
    workspaces:
    builtins.toFile "seter-http-policy.toml" (
      "version = 1\n"
      + lib.concatMapStrings (name: ''
        [workspaces.${name}.egress]
        http-hosts = ["API.Example.COM"]
      '') (builtins.attrNames workspaces)
    );
  httpConfigurationRejected =
    workspaces:
    hostConfigurationRejected {
      policyFile = httpPolicyFileFor workspaces;
      inherit workspaces;
    };

  # Named cases retain diagnostics without repeating whole fixtures.
  networkRejections = {
    duplicateIp = {
      alpha = validWorkspaces.alpha;
      beta = lib.recursiveUpdate validWorkspaces.beta {
        network.address = validWorkspaces.alpha.network.address;
      };
    };
    duplicateMac = {
      alpha = validWorkspaces.alpha;
      beta = lib.recursiveUpdate validWorkspaces.beta {
        network.mac = validWorkspaces.alpha.network.mac;
      };
    };
    duplicateTap = {
      alpha = validWorkspaces.alpha;
      beta = lib.recursiveUpdate validWorkspaces.beta {
        network.tap = validWorkspaces.alpha.network.tap;
      };
    };
    duplicateHostname = {
      alpha = validWorkspaces.alpha;
      beta = validWorkspaces.beta // {
        hostname = "alpha.vm";
      };
    };
  }
  //
    lib.mapAttrs
      (_: overrides: {
        broken = mkTestWorkspace (
          {
            ip = "10.100.0.12";
            mac = "02:00:00:00:00:12";
            tap = "seter-broken";
          }
          // overrides
        );
      })
      {
        invalidIp.ip = "10.100.0.999";
        outOfSubnetIp.ip = "10.101.0.12";
        gatewayIp.ip = "10.100.0.1";
        networkIp.ip = "10.100.0.0";
        bridgeTap.tap = "seter0";
      };
  networkRejectionsPass = lib.all (
    name:
    lib.assertMsg (configurationRejected
      networkRejections.${name}
    ) "Expected workspace configuration rejection: ${name}"
  ) (builtins.attrNames networkRejections);

  outOfSubnetGatewayRejected =
    !(builtins.tryEval (
      builtins.deepSeq
        (inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.host
            hostModuleBase
            {
              seter.host = {
                gateway = "10.101.0.1";
                workspaces = validWorkspaces;
              };
            }
          ];
        }).config.system.build.toplevel.drvPath
        true
    )).success;

  nonHttpsRepositoryRejected = configurationRejected {
    broken = validWorkspaces.alpha // {
      repositories.workspace = validWorkspaces.alpha.repositories.workspace // {
        url = "ssh://git@example.invalid/owner/workspace.git";
      };
    };
  };

  invalidRepositoryHostRejected = configurationRejected {
    broken = validWorkspaces.alpha // {
      repositories.workspace = validWorkspaces.alpha.repositories.workspace // {
        url = "https://./owner/workspace.git";
      };
    };
  };

  traversingCheckoutNameRejected = configurationRejected {
    broken = validWorkspaces.alpha // {
      repositories.workspace = validWorkspaces.alpha.repositories.workspace // {
        checkoutName = "..";
      };
    };
  };

  reusedStorageImageRejected = configurationRejected {
    broken = validWorkspaces.alpha // {
      storage = validWorkspaces.alpha.storage // {
        project = {
          image = "reused.img";
          sizeMiB = 4096;
        };
        nixStore = {
          image = "reused.img";
          sizeMiB = 16384;
        };
      };
    };
  };

  blankSecretPlaceholderRejected = httpConfigurationRejected {
    broken = validWorkspaces.alpha // {
      secrets.token = {
        placeholder = "   ";
        sourceFile = "/run/secrets/token";
        hosts = [ "api.example.com" ];
        headers = [ "authorization" ];
      };
    };
  };

  nonDistinctiveSecretPlaceholderRejected = httpConfigurationRejected {
    broken = validWorkspaces.alpha // {
      secrets.token = {
        placeholder = "placeholder-token";
        sourceFile = "/run/secrets/token";
        hosts = [ "api.example.com" ];
        headers = [ "authorization" ];
      };
    };
  };

  storeSecretSourceRejected = httpConfigurationRejected {
    broken = validWorkspaces.alpha // {
      secrets.token = {
        placeholder = "seter-placeholder-0123456789abcdef";
        sourceFile = "/nix/store/example-secret";
        hosts = [ "api.example.com" ];
        headers = [ "authorization" ];
      };
    };
  };

  caseInsensitiveSecretHostAccepted =
    (forceConfiguration (mkHostWith {
      policyFile = httpPolicyFileFor { alpha = { }; };
      workspaces.alpha = validWorkspaces.alpha // {
        secrets.token = {
          placeholder = "seter-placeholder-0123456789abcdef";
          sourceFile = "/run/secrets/token";
          hosts = [ "api.example.com" ];
          headers = [ "Authorization" ];
        };
      };
    })).success;

  duplicateSecretPlaceholderRejected = httpConfigurationRejected {
    alpha = validWorkspaces.alpha // {
      secrets = {
        first = {
          placeholder = "seter-placeholder-0123456789abcdef";
          sourceFile = "/run/secrets/first";
          hosts = [ "api.example.com" ];
          headers = [ "authorization" ];
        };
        second = {
          placeholder = "seter-placeholder-0123456789abcdef";
          sourceFile = "/run/secrets/second";
          hosts = [ "api.example.com" ];
          headers = [ "x-api-key" ];
        };
      };
    };
  };

  overlappingSecretPlaceholderRejected = httpConfigurationRejected {
    alpha = validWorkspaces.alpha // {
      secrets = {
        first = {
          placeholder = "seter-placeholder-0123456789abcdef";
          sourceFile = "/run/secrets/first";
          hosts = [ "api.example.com" ];
          headers = [ "authorization" ];
        };
        second = {
          placeholder = "seter-placeholder-0123456789abcdef-extra";
          sourceFile = "/run/secrets/second";
          hosts = [ "api.example.com" ];
          headers = [ "x-api-key" ];
        };
      };
    };
  };

  invalidSecretNameRejected = httpConfigurationRejected {
    alpha = validWorkspaces.alpha // {
      secrets."bad:name" = {
        placeholder = "seter-placeholder-0123456789abcdef";
        sourceFile = "/run/secrets/token";
        hosts = [ "api.example.com" ];
        headers = [ "authorization" ];
      };
    };
  };

  passthroughSecretHostRejected = hostConfigurationRejected {
    policyFile = builtins.toFile "seter-passthrough-secret-policy.toml" ''
      version = 1
      [workspaces.alpha.egress]
      passthrough-hosts = ["api.example.com"]
    '';
    workspaces.alpha = validWorkspaces.alpha // {
      secrets.token = {
        placeholder = "seter-placeholder-0123456789abcdef";
        sourceFile = "/run/secrets/token";
        hosts = [ "api.example.com" ];
        headers = [ "authorization" ];
      };
    };
  };

  duplicateSecretHostRejected = httpConfigurationRejected {
    alpha = validWorkspaces.alpha // {
      secrets.token = {
        placeholder = "seter-placeholder-0123456789abcdef";
        sourceFile = "/run/secrets/token";
        hosts = [
          "api.example.com"
          "API.EXAMPLE.COM"
        ];
        headers = [ "authorization" ];
      };
    };
  };

  duplicateSecretHeaderRejected = httpConfigurationRejected {
    alpha = validWorkspaces.alpha // {
      secrets.token = {
        placeholder = "seter-placeholder-0123456789abcdef";
        sourceFile = "/run/secrets/token";
        hosts = [ "api.example.com" ];
        headers = [
          "authorization"
          "Authorization"
        ];
      };
    };
  };

  emptySecretHeadersRejected = httpConfigurationRejected {
    alpha = validWorkspaces.alpha // {
      secrets.token = {
        placeholder = "seter-placeholder-0123456789abcdef";
        sourceFile = "/run/secrets/token";
        hosts = [ "api.example.com" ];
        headers = [ ];
      };
    };
  };

  prohibitedSecretHeaderRejected = httpConfigurationRejected {
    alpha = validWorkspaces.alpha // {
      secrets.token = {
        placeholder = "seter-placeholder-0123456789abcdef";
        sourceFile = "/run/secrets/token";
        hosts = [ "api.example.com" ];
        headers = [ "Host" ];
      };
    };
  };

  overlappingProxyHostsRejected = hostConfigurationRejected {
    policyFile = builtins.toFile "seter-overlapping-hosts-policy.toml" ''
      version = 1
      [workspaces.alpha.egress]
      http-hosts = ["API.Example.COM"]
      passthrough-hosts = ["api.example.com"]
    '';
    workspaces = validWorkspaces;
  };

  proxyPortAsDirectTcpRejected = hostConfigurationRejected {
    policyFile = builtins.toFile "seter-proxy-port-policy.toml" ''
      version = 1
      [[workspaces.alpha.egress.tcp]]
      host = "api.example.com"
      port = 443
    '';
    workspaces = validWorkspaces;
  };

  proxyPortCollisionRejected =
    !(builtins.tryEval (
      builtins.deepSeq
        (inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.host
            hostModuleBase
            {
              seter.host = {
                proxy.explicitPort = 18080;
                workspaces = validWorkspaces;
              };
            }
          ];
        }).config.system.build.toplevel.drvPath
        true
    )).success;

  importedPolicyFile = builtins.toFile "seter-test-policy.toml" ''
    version = 1

    [workspaces.alpha.egress]
    http-hosts = ["*.example.com"]
    passthrough-hosts = ["downloads.example.net"]

    [[workspaces.alpha.egress.tcp]]
    host = "ssh.example.org"
    port = 2222
  '';
  importedPolicyConfiguration = mkHostWith {
    policyFile = importedPolicyFile;
    workspaces = validWorkspaces;
  };
  importedPolicyAlpha = importedPolicyConfiguration.config.seter.host.workspaces.alpha.egress;

  recursivePolicyWildcardRejected = hostConfigurationRejected {
    policyFile = builtins.toFile "seter-recursive-policy.toml" ''
      version = 1
      [workspaces.alpha.egress]
      http-hosts = ["*.*.example.com"]
    '';
    workspaces = validWorkspaces;
  };
  sharedHostingPolicyWildcardRejected = hostConfigurationRejected {
    policyFile = builtins.toFile "seter-shared-hosting-policy.toml" ''
      version = 1
      [workspaces.alpha.egress]
      http-hosts = ["*.github.io"]
    '';
    workspaces = validWorkspaces;
  };
  overlappingWildcardPolicyRejected = hostConfigurationRejected {
    policyFile = builtins.toFile "seter-overlapping-policy.toml" ''
      version = 1
      [workspaces.alpha.egress]
      http-hosts = ["*.example.com"]
      passthrough-hosts = ["api.example.com"]
    '';
    workspaces = validWorkspaces;
  };
  wildcardDirectTcpPolicyRejected = hostConfigurationRejected {
    policyFile = builtins.toFile "seter-wildcard-tcp-policy.toml" ''
      version = 1
      [[workspaces.alpha.egress.tcp]]
      host = "*.example.com"
      port = 2222
    '';
    workspaces = validWorkspaces;
  };
  unknownPolicyWorkspaceRejected = hostConfigurationRejected {
    policyFile = builtins.toFile "seter-unknown-workspace-policy.toml" ''
      version = 1
      [workspaces.missing.egress]
      http-hosts = ["api.example.com"]
    '';
    workspaces = validWorkspaces;
  };

  dnsBurstRejected = hostConfigurationRejected {
    dns = {
      queriesPerSecond = 100;
      queryBurst = 99;
    };
    workspaces = validWorkspaces;
  };

  excessiveDnsTimeoutRejected = hostConfigurationRejected {
    dns.upstreamTimeoutSeconds = 61;
    workspaces = validWorkspaces;
  };

  insufficientDnsTimeoutRejected = hostConfigurationRejected {
    dns.upstreamTimeoutSeconds = 0.09;
    workspaces = validWorkspaces;
  };

  undefinedHostServiceRejected = configurationRejected {
    alpha = validWorkspaces.alpha // {
      hostServices = [ "missing" ];
    };
  };

  duplicateWorkspaceHostServiceRejected = hostConfigurationRejected {
    gatewayServices.adb = {
      listenPort = 5037;
      targetPort = 15037;
    };
    workspaces.alpha = validWorkspaces.alpha // {
      hostServices = [
        "adb"
        "adb"
      ];
    };
  };

  duplicateGatewayServicePortRejected = hostConfigurationRejected {
    gatewayServices = {
      adb = {
        listenPort = 5037;
        targetPort = 15037;
      };
      builder = {
        listenPort = 5037;
        targetPort = 15038;
      };
    };
    workspaces = validWorkspaces;
  };

  gatewayServiceProxyPortRejected = hostConfigurationRejected {
    gatewayServices.bad = {
      listenPort = 18080;
      targetPort = 15037;
    };
    workspaces = validWorkspaces;
  };

  gatewayServiceDnsPortRejected = hostConfigurationRejected {
    gatewayServices.bad = {
      listenPort = alphaDnsPort;
      targetPort = 15037;
    };
    workspaces = validWorkspaces;
  };

  invalidGatewayServiceNameRejected = hostConfigurationRejected {
    gatewayServices."Bad_Name" = {
      listenPort = 5037;
      targetPort = 15037;
    };
    workspaces = validWorkspaces;
  };

  nonLoopbackGatewayTargetRejected = hostConfigurationRejected {
    gatewayServices.bad = {
      listenPort = 5037;
      targetAddress = "192.0.2.10";
      targetPort = 15037;
    };
    workspaces = validWorkspaces // {
      alpha = validWorkspaces.alpha // {
        hostServices = [ "bad" ];
      };
    };
  };

  tcpWithoutFirewallRejected =
    !(builtins.tryEval (
      builtins.deepSeq
        (inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.host
            hostModuleBase
            {
              networking.firewall.enable = false;
              seter.host = {
                policyFile = tcpPolicyFile;
                workspaces = validWorkspaces;
              };
            }
          ];
        }).config.system.build.toplevel.drvPath
        true
    )).success;

  tcpWithoutForwardFilterRejected =
    !(builtins.tryEval (
      builtins.deepSeq
        (inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.host
            hostModuleBase
            {
              networking.firewall.filterForward = false;
              seter.host = {
                policyFile = tcpPolicyFile;
                workspaces = validWorkspaces;
              };
            }
          ];
        }).config.system.build.toplevel.drvPath
        true
    )).success;

  # These baselines must pass before rejection results mean anything. Force
  # module options and assertions, rather than accepting any toplevel failure.
  mkGuest =
    overrides:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.guest
        {
          seter.guest.enable = true;
          system.stateVersion = "24.11";
        }
        overrides
      ];
    };
  mkGeneratedGuest = overrides: identityGuestConfiguration.extendModules { modules = [ overrides ]; };
  guestRejections = {
    privateProxyKey.seter.guest.proxyCaCertificate = ''
      -----BEGIN CERTIFICATE-----
      invalid-test-certificate
      -----END CERTIFICATE-----
      -----BEGIN PRIVATE KEY-----
      must-never-enter-the-store
      -----END PRIVATE KEY-----
    '';
    invalidPlaceholderName.seter.guest.secretPlaceholders."INVALID-NAME" =
      "seter-placeholder-invalid-0123456789abcdef";
    invalidPlaceholderValue.seter.guest.secretPlaceholders.GITHUB_TOKEN = "this-would-be-a-real-secret";
    proxyPlaceholderName.seter.guest.secretPlaceholders.HTTPS_PROXY =
      "seter-placeholder-invalid-0123456789abcdef";
    overlappingPlaceholders.seter.guest.secretPlaceholders = {
      FIRST_TOKEN = "seter-placeholder-0123456789abcdef";
      SECOND_TOKEN = "seter-placeholder-0123456789abcdef-extra";
    };
  };
  # Each case changes one setting. A rejected bundle of overrides only proves
  # that at least one guard works and can conceal a broken guard in another.
  generatedGuestRejections = {
    memory.seter.guest.memory = lib.mkForce 1024;
    identity.seter.guest.network.address = lib.mkForce "10.100.0.99";
    interfaces.microvm.interfaces = lib.mkForce [ ];
    nameservers.networking.nameservers = lib.mkForce [ "8.8.8.8" ];
    projectVolume.seter.guest.projectVolume.enable = lib.mkForce false;
    homeVolume.seter.guest.homeVolume.enable = lib.mkForce false;
    nixStore.seter.guest.nixStore.enable = lib.mkForce false;
    ssh.seter.guest.ssh.enable = lib.mkForce false;
    nixSandbox.nix.settings.sandbox = lib.mkForce false;
    nixGc.nix.settings.min-free = lib.mkForce 1;
    effectiveProxy.environment.sessionVariables.HTTP_PROXY = lib.mkForce "http://127.0.0.1:9999";
    proxyCa.seter.guest.proxyCaCertificate = lib.mkForce null;
  };
  lib = pkgs.lib;
  alphaDnsPort =
    (import ../nix/modules/host/dns-ports.nix {
      inherit lib;
      workspaces = validWorkspaces;
    }).alpha;
  tcpPolicyFile = builtins.toFile "seter-tcp-policy.toml" ''
    version = 1
    [[workspaces.alpha.egress.tcp]]
    host = "direct.example"
    port = 2222
  '';
  hostChecks = {
    inherit
      networkRejectionsPass
      outOfSubnetGatewayRejected
      nonHttpsRepositoryRejected
      invalidRepositoryHostRejected
      traversingCheckoutNameRejected
      reusedStorageImageRejected
      blankSecretPlaceholderRejected
      nonDistinctiveSecretPlaceholderRejected
      storeSecretSourceRejected
      caseInsensitiveSecretHostAccepted
      duplicateSecretPlaceholderRejected
      overlappingSecretPlaceholderRejected
      invalidSecretNameRejected
      passthroughSecretHostRejected
      duplicateSecretHostRejected
      duplicateSecretHeaderRejected
      emptySecretHeadersRejected
      prohibitedSecretHeaderRejected
      overlappingProxyHostsRejected
      proxyPortAsDirectTcpRejected
      proxyPortCollisionRejected
      recursivePolicyWildcardRejected
      sharedHostingPolicyWildcardRejected
      overlappingWildcardPolicyRejected
      wildcardDirectTcpPolicyRejected
      unknownPolicyWorkspaceRejected
      dnsBurstRejected
      excessiveDnsTimeoutRejected
      insufficientDnsTimeoutRejected
      undefinedHostServiceRejected
      duplicateWorkspaceHostServiceRejected
      duplicateGatewayServicePortRejected
      gatewayServiceProxyPortRejected
      gatewayServiceDnsPortRejected
      invalidGatewayServiceNameRejected
      nonLoopbackGatewayTargetRejected
      tcpWithoutFirewallRejected
      tcpWithoutForwardFilterRejected
      ;
  };
in
assert lib.all (name: lib.assertMsg hostChecks.${name} "Configuration check failed: ${name}") (
  builtins.attrNames hostChecks
);
assert lib.assertMsg (forceConfiguration (mkHost validWorkspaces)).success
  "Valid host baseline rejected";
assert lib.assertMsg (forceConfiguration (mkGuest { })).success "Valid guest baseline rejected";
assert lib.assertMsg (forceConfiguration (mkGeneratedGuest { })).success
  "Valid generated guest baseline rejected";
assert lib.all (
  name:
  lib.assertMsg (
    !(forceConfiguration (mkGuest guestRejections.${name})).success
  ) "Expected guest configuration rejection: ${name}"
) (builtins.attrNames guestRejections);
assert lib.all (
  name:
  lib.assertMsg (
    !(forceConfiguration (mkGeneratedGuest generatedGuestRejections.${name})).success
  ) "Expected generated guest rejection: ${name}"
) (builtins.attrNames generatedGuestRejections);
assert lib.all
  (
    ports:
    configurationRejected {
      alpha = validWorkspaces.alpha // {
        developmentPorts = ports;
      };
    }
  )
  [
    [ 22 ]
    [ 65536 ]
    [
      3000
      3000
    ]
  ];
assert builtins.elem "*.example.com" importedPolicyAlpha.httpHosts;
assert builtins.elem "downloads.example.net" importedPolicyAlpha.passthroughHosts;
assert builtins.elem {
  host = "ssh.example.org";
  port = 2222;
} importedPolicyAlpha.tcp;
pkgs.runCommand "seter-workspace-uniqueness-check" { } ''
  touch "$out"
''
