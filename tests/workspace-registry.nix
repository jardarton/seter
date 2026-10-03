{
  self,
  lib,
  pkgs,
  system,
  fixtures,
  hostConfiguration,
  minimalConfiguration,
}:
let
  inherit (fixtures)
    mkHostWith
    validWorkspaces
    identityHostConfiguration
    terminalProfile
    identityRegistryFile
    identityDesiredPolicyFile
    identityGuestConfiguration
    qemuIdentityGuestConfiguration
    ;
  dnsPortsFor = workspaces: import ../nix/modules/host/dns-ports.nix { inherit lib workspaces; };
  workspaceDnsPorts = dnsPortsFor validWorkspaces;
  approvedStoreSeed = pkgs.writeText "seter-registry-approved-store-seed" "approved\n";
  approvedGuestPackage = pkgs.writeShellScriptBin "workspace-helper" "echo ready";
  seededHostConfiguration = mkHostWith {
    guestProfiles.terminal = terminalProfile;
    workspaces = validWorkspaces // {
      alpha = validWorkspaces.alpha // {
        guestProfile = "terminal";
        storeSeeds = [ approvedStoreSeed ];
        guestPackages = [ approvedGuestPackage ];
      };
    };
  };
  seededProjection = import ../nix/modules/host/projections.nix {
    cfg = seededHostConfiguration.config.seter.host;
    inherit lib pkgs;
    seterMicrovmModule = self.inputs.microvm.nixosModules.microvm;
    subnetPrefix = 24;
    parseIpv4 = import ../nix/lib/ipv4.nix { inherit lib; };
  };
  alphaDnsPort = workspaceDnsPorts.alpha;
  betaDnsPort = workspaceDnsPorts.beta;
  alphaDnsPortWithEarlierWorkspace = (dnsPortsFor ({ aardvark = { }; } // validWorkspaces)).alpha;

  tcpPolicyFile = builtins.toFile "seter-tcp-policy.toml" ''
    version = 1
    [[workspaces.alpha.egress.tcp]]
    host = "direct.example"
    port = 2222
  '';
  tcpHostConfiguration = mkHostWith {
    policyFile = tcpPolicyFile;
    workspaces = validWorkspaces;
  };

  gatewayServiceWorkspaces = validWorkspaces // {
    alpha = validWorkspaces.alpha // {
      hostServices = [ "adb" ];
    };
  };
  gatewayServiceConfiguration = mkHostWith {
    workspaces = gatewayServiceWorkspaces;
    gatewayServices.adb = {
      listenPort = 5037;
      targetPort = 15037;
    };
  };
  gatewayServiceSocket = gatewayServiceConfiguration.config.systemd.sockets.seter-gateway-adb;
  gatewayService = gatewayServiceConfiguration.config.systemd.services.seter-gateway-adb;
  gatewayServiceTapRequires =
    gatewayServiceConfiguration.config.systemd.services.seter-tap-alpha.requires;
  gatewayServiceFirewallPorts =
    gatewayServiceConfiguration.config.networking.firewall.interfaces.seter0.allowedTCPPorts;

  secretPolicyWorkspaces = validWorkspaces // {
    alpha = validWorkspaces.alpha // {
      secrets.githubToken = {
        placeholder = "seter-placeholder-0123456789abcdef";
        sourceFile = "/run/secrets/github-token";
        hosts = [ "Api.Example.Com" ];
        headers = [
          "Authorization"
          "X-Api-Key"
        ];
      };
    };
  };
  secretPolicyConfiguration = mkHostWith {
    policyFile = httpPolicyFileFor secretPolicyWorkspaces;
    workspaces = secretPolicyWorkspaces;
  };
  secretPolicyService = secretPolicyConfiguration.config.systemd.services.seter-proxy;
  secretPolicyFile = builtins.head secretPolicyService.restartTriggers;
  secretPolicyCredentials = secretPolicyService.serviceConfig.LoadCredential;

  qemuHostConfiguration = mkHostWith {
    runner.hypervisor = "qemu";
    workspaces = lib.mapAttrs (
      _: workspace:
      workspace
      // {
        resources = workspace.resources // {
          vcpu = 4;
        };
      }
    ) validWorkspaces;
  };
  registryFile = hostConfiguration.config.environment.etc."seter/workspaces.json".source;
  minimalIdentityShare = builtins.head minimalConfiguration.config.microvm.shares;
  minimalIdentitySocket = minimalIdentityShare.socket;
  minimalStoreOnDisk = minimalConfiguration.config.microvm.storeOnDisk;
  alphaDeviceAllow =
    hostConfiguration.config.systemd.services.seter-vm-alpha.serviceConfig.DeviceAllow;
  alphaTapRequires = hostConfiguration.config.systemd.services.seter-tap-alpha.requires;
  dnsService = hostConfiguration.config.systemd.services.seter-dns-alpha;
  dnsPolicyFile = builtins.head dnsService.restartTriggers;
  dnsUpstreamService = hostConfiguration.config.systemd.services.seter-dns-upstream;
  proxyService = hostConfiguration.config.systemd.services.seter-proxy;
  proxyPort = hostConfiguration.config.seter.host.proxy.port;
  explicitProxyPort = hostConfiguration.config.seter.host.proxy.explicitPort;
  tcpService = tcpHostConfiguration.config.systemd.services.seter-tcp-egress-alpha;
  tcpTapRequires = tcpHostConfiguration.config.systemd.services.seter-tap-alpha.requires;
  tcpNftablesConfig = tcpHostConfiguration.config.networking.nftables;
  tcpFirewallForwardRules = tcpHostConfiguration.config.networking.firewall.extraForwardRules;
  nftablesConfig = hostConfiguration.config.networking.nftables;
  lifecycleSudoRules = lib.filter (
    rule: builtins.elem "seter-operators" (rule.groups or [ ])
  ) hostConfiguration.config.security.sudo.extraRules;
  lifecycleSudoCommands = lib.concatMap (
    rule: if builtins.elem "seter-operators" (rule.groups or [ ]) then rule.commands else [ ]
  ) hostConfiguration.config.security.sudo.extraRules;
  lifecycleHelper = lib.getExe hostConfiguration.config.seter.host.package;
  qemuGuestCredentials = qemuIdentityGuestConfiguration.config.microvm.credentialFiles;
  qemuGuestShares = qemuIdentityGuestConfiguration.config.microvm.shares;
  qemuGuestIdentityService =
    qemuIdentityGuestConfiguration.config.systemd.services.seter-ssh-identity;
  qemuVmService = qemuHostConfiguration.config.systemd.services.seter-vm-alpha;
  qemuRuntimeTarget = qemuHostConfiguration.config.systemd.targets.seter-runtime-alpha;

  httpPolicyFileFor =
    workspaces:
    builtins.toFile "seter-http-policy.toml" (
      "version = 1\n"
      + lib.concatMapStrings (name: ''
        [workspaces.${name}.egress]
        http-hosts = ["API.Example.COM"]
      '') (builtins.attrNames workspaces)
    );
in
assert seededProjection.workspaceSystems.alpha.config.users.users.seter.shell == pkgs.zsh;
assert builtins.elem pkgs.hello
  seededProjection.workspaceSystems.alpha.config.environment.systemPackages;
assert seededProjection.workspaceSystems.alpha.config.programs.direnv.nix-direnv.enable;
assert lib.all (entry: entry.assertion) seededProjection.workspaceSystems.alpha.config.assertions;
assert seededProjection.lifecycleRegistry.workspaces.alpha.guestProfile == "terminal";
assert
  seededProjection.lifecycleRegistry.workspaces.alpha.runner.identity.guestProfile == "terminal";
assert hostConfiguration.config.seter.host.workspaces.alpha.storeSeeds == [ ];
assert hostConfiguration.config.seter.host.workspaces.alpha.guestPackages == [ ];
assert builtins.elem approvedGuestPackage
  seededProjection.workspaceSystems.alpha.config.environment.systemPackages;
assert
  !(builtins.elem approvedGuestPackage seededProjection.workspaceSystems.beta.config.environment.systemPackages);
assert
  !(builtins.elem approvedStoreSeed seededProjection.workspaceSystems.alpha.config.environment.systemPackages);
assert
  seededProjection.workspaceSystems.alpha.config.system.extraDependencies == [ approvedStoreSeed ];
assert seededProjection.workspaceSystems.beta.config.system.extraDependencies == [ ];
assert minimalIdentitySocket == "/run/seter/minimal/virtiofs-identity.sock";
assert minimalIdentityShare.source == "/run/credentials/seter-identity-virtiofsd-minimal.service";
assert minimalStoreOnDisk;
assert builtins.elem "vhost_vsock" hostConfiguration.config.boot.kernelModules;
assert builtins.elem "/dev/vhost-vsock rw" alphaDeviceAllow;
assert builtins.elem "nftables.service" alphaTapRequires;
assert builtins.elem "seter-dns-alpha.service" alphaTapRequires;
assert builtins.elem "seter-proxy.service" alphaTapRequires;
assert builtins.elem "seter-bridge.service" dnsService.requires;
assert builtins.elem "nftables.service" dnsService.requires;
assert builtins.elem "seter-dns-upstream.service" dnsService.requires;
assert dnsService.serviceConfig.MemoryMax == 128 * 1024 * 1024;
assert dnsUpstreamService.unitConfig.StopWhenUnneeded;
assert builtins.elem "seter-bridge.service" proxyService.requires;
assert builtins.elem "nftables.service" proxyService.requires;
assert proxyService.serviceConfig.MemoryMax == 1024 * 1024 * 1024;
assert alphaDnsPort == alphaDnsPortWithEarlierWorkspace;
assert alphaDnsPort != betaDnsPort;
assert builtins.elem "alpha.vm" hostConfiguration.config.networking.hosts."10.100.0.10";
assert builtins.elem alphaDnsPort
  hostConfiguration.config.networking.firewall.interfaces.seter0.allowedTCPPorts;
assert builtins.elem alphaDnsPort
  hostConfiguration.config.networking.firewall.interfaces.seter0.allowedUDPPorts;
assert builtins.elem proxyPort
  hostConfiguration.config.networking.firewall.interfaces.seter0.allowedTCPPorts;
assert builtins.elem explicitProxyPort
  hostConfiguration.config.networking.firewall.interfaces.seter0.allowedTCPPorts;
assert builtins.elem 5037 gatewayServiceFirewallPorts;
assert builtins.elem "seter-gateway-adb.socket" gatewayServiceTapRequires;
assert builtins.elem "seter-bridge.service" gatewayServiceSocket.requires;
assert builtins.elem "nftables.service" gatewayServiceSocket.requires;
assert gatewayServiceSocket.unitConfig.StopWhenUnneeded;
assert gatewayService.serviceConfig.DynamicUser;
assert lib.hasInfix "systemd-socket-proxyd --exit-idle-time=5s 127.0.0.1:15037"
  gatewayService.serviceConfig.ExecStart;
assert nftablesConfig.enable;
assert nftablesConfig.tables.seter_l2.family == "bridge";
assert nftablesConfig.tables.seter_l3.family == "inet";
assert nftablesConfig.tables.seter_dns.family == "inet";
assert nftablesConfig.tables.seter_proxy.family == "inet";
assert nftablesConfig.tables.seter_proxy_output.family == "inet";
assert builtins.elem "seter-tcp-egress-alpha.service" tcpTapRequires;
assert builtins.elem "nftables.service" tcpService.requires;
assert tcpNftablesConfig.tables.seter_tcp_nat.family == "ip";
assert tcpHostConfiguration.config.boot.kernel.sysctl."net.ipv4.ip_forward" == 1;
assert tcpHostConfiguration.config.networking.firewall.filterForward;
assert lib.hasInfix ''iifname "seter0"'' tcpFirewallForwardRules;
assert lib.hasInfix "10.100.0.10" tcpFirewallForwardRules;
assert builtins.any (
  entry: entry.command == "${lifecycleHelper} __start alpha" && builtins.elem "NOPASSWD" entry.options
) lifecycleSudoCommands;
assert builtins.any (
  entry: entry.command == "${lifecycleHelper} __stop alpha" && builtins.elem "NOPASSWD" entry.options
) lifecycleSudoCommands;
assert lib.all (rule: rule.runAs == "root") lifecycleSudoRules;
assert lib.all (entry: !(lib.hasInfix "*" entry.command)) lifecycleSudoCommands;
assert proxyService.serviceConfig.LoadCredential == [ ];
assert builtins.elem hostConfiguration.config.environment.etc."seter/runners/alpha".source
  hostConfiguration.config.system.extraDependencies;
assert lib.hasInfix
  (builtins.unsafeDiscardStringContext (
    toString hostConfiguration.config.environment.etc."seter/runners/alpha".source
  ))
  (
    builtins.unsafeDiscardStringContext hostConfiguration.config.systemd.services.seter-vm-alpha.serviceConfig.ExecStop
  );
assert
  !lib.hasInfix "/var/lib/seter/workspaces/alpha/current" (
    builtins.unsafeDiscardStringContext hostConfiguration.config.systemd.services.seter-vm-alpha.serviceConfig.ExecStop
  );
assert lib.hasInfix "seter-vm-alpha-stop"
  hostConfiguration.config.systemd.services.seter-vm-alpha.serviceConfig.ExecStop;
assert
  hostConfiguration.config.systemd.services.seter-vm-alpha.serviceConfig.TimeoutStopSec == "60s";
assert lib.hasInfix "/seter-alpha.sock"
  qemuHostConfiguration.config.systemd.services.seter-vm-alpha.serviceConfig.ExecStop;
assert lib.hasInfix
  (builtins.unsafeDiscardStringContext (
    toString qemuHostConfiguration.config.environment.etc."seter/runners/alpha".source
  ))
  (
    builtins.unsafeDiscardStringContext qemuHostConfiguration.config.systemd.services.seter-vm-alpha.serviceConfig.ExecStop
  );
assert identityHostConfiguration.config.seter.host.workspaces.identity.guestProfile == "terminal";
assert identityGuestConfiguration.config.seter.guest.name == "identity";
assert identityGuestConfiguration.config.programs.direnv.enable;
assert identityGuestConfiguration.config.programs.direnv.enableBashIntegration;
assert identityGuestConfiguration.config.programs.direnv.nix-direnv.enable;
assert builtins.elem "nix-command"
  identityGuestConfiguration.config.nix.settings.experimental-features;
assert builtins.elem "flakes" identityGuestConfiguration.config.nix.settings.experimental-features;
assert identityGuestConfiguration.config.security.pki.installCACerts;
assert identityGuestConfiguration.config.seter.guest.network.address == "10.100.0.12";
assert identityGuestConfiguration.config.seter.guest.network.mac == "02:00:00:00:00:12";
assert identityGuestConfiguration.config.seter.guest.network.tap == "seter-identity";
assert identityGuestConfiguration.config.seter.guest.network.gateway == "10.100.0.1";
assert identityGuestConfiguration.config.seter.guest.proxy == "http://10.100.0.1:18081";
assert identityGuestConfiguration.config.seter.guest.nixStore.enable;
assert identityGuestConfiguration.config.seter.guest.homeVolume.enable;
assert identityGuestConfiguration.config.seter.guest.homeVolume.image == "identity-home.img";
assert identityGuestConfiguration.config.seter.guest.homeVolume.size == 4096;
assert identityGuestConfiguration.config.seter.guest.nixStore.image == "identity-nix-store.img";
assert identityGuestConfiguration.config.seter.guest.nixStore.size == 16384;
assert identityGuestConfiguration.config.seter.guest.vcpu == 2;
assert identityGuestConfiguration.config.microvm.vcpu == 2;
assert identityGuestConfiguration.config.microvm.writableStoreOverlay == "/nix/.rw-store";
assert identityGuestConfiguration.config.microvm.storeOnDisk;
assert
  !(lib.any (share: share.source == "/nix/store") identityGuestConfiguration.config.microvm.shares);
assert identityGuestConfiguration.config.fileSystems."/nix".neededForBoot;
assert identityGuestConfiguration.config.nix.settings.sandbox;
assert !identityGuestConfiguration.config.nix.settings.auto-optimise-store;
assert !identityGuestConfiguration.config.nix.optimise.automatic;
assert !identityGuestConfiguration.config.nix.gc.automatic;
assert identityGuestConfiguration.config.nix.settings.min-free == 0;
assert identityGuestConfiguration.config.nix.settings.max-free == 0;
assert identityGuestConfiguration.config.nix.settings.gc-reserved-space == 0;
assert
  identityGuestConfiguration.config.environment.sessionVariables.GITHUB_TOKEN
  == "seter-placeholder-github-0123456789abcdef";
assert
  identityGuestConfiguration.config.environment.sessionVariables.GH_TOKEN
  == "seter-placeholder-github-0123456789abcdef";
assert
  secretPolicyCredentials == [
    "seter-alpha.githubToken:/run/secrets/github-token"
  ];
assert qemuIdentityGuestConfiguration.config.seter.guest.hypervisor == "qemu";
assert qemuIdentityGuestConfiguration.config.seter.guest.ssh.identityTransport == "fw_cfg";
assert qemuIdentityGuestConfiguration.config.seter.guest.vcpu == 4;
assert qemuIdentityGuestConfiguration.config.microvm.vcpu == 4;
assert qemuGuestShares == [ ];
assert
  qemuGuestCredentials == {
    "seter.ssh-host-key" = "/run/credentials/seter-vm-identity.service/ssh_host_ed25519_key";
  };
assert qemuGuestIdentityService.serviceConfig.ImportCredential == [ "seter.ssh-host-key" ];
assert
  qemuVmService.serviceConfig.LoadCredential == [
    "ssh_host_ed25519_key:/var/lib/seter/identities/alpha/ssh_host_ed25519_key"
  ];
assert qemuRuntimeTarget.requires == [ "seter-tap-alpha.service" ];
assert
  !(builtins.hasAttr "seter-identity-virtiofsd-alpha" qemuHostConfiguration.config.systemd.services);
pkgs.runCommand "seter-workspace-registry-check" { } ''
  ${pkgs.python3}/bin/python ${./registry-projections.py} \
    ${registryFile} ${identityRegistryFile} \
    ${identityHostConfiguration.config.environment.etc."seter/runners/identity".source} \
    ${dnsPolicyFile} ${secretPolicyFile}
  ${pkgs.python3}/bin/python ${./workspace-cli.py} \
    ${lib.getExe self.packages.${system}.seter} \
    ${registryFile} ${identityRegistryFile} ${identityDesiredPolicyFile}
  touch "$out"
''
