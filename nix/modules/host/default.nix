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
    concatMap
    mapAttrs
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    types
    unique
    ;

  workspaceType = types.submodule (import ./workspace.nix);
  workspaces = mapAttrsToList (name: workspace: workspace // { inherit name; }) cfg.workspaces;

  valuesFor = select: map select workspaces;
  hasUniqueValues = values: builtins.length values == builtins.length (unique values);
  nonBlank = value: builtins.match ".*[^[:space:]].*" value != null;

  parseIpv4 =
    address:
    let
      rawParts = lib.splitString "." address;
      parsePart =
        part: if builtins.match "(0|[1-9][0-9]{0,2})" part == null then null else lib.toInt part;
      parts = map parsePart rawParts;
      valid = builtins.length parts == 4 && lib.all (part: part != null && part <= 255) parts;
    in
    if valid then lib.foldl' (value: part: value * 256 + part) 0 parts else null;

  pow2 = exponent: if exponent == 0 then 1 else 2 * pow2 (exponent - 1);
  subnetParts = lib.splitString "/" cfg.subnet;
  subnetAddress = parseIpv4 (builtins.elemAt subnetParts 0);
  subnetPrefix = lib.toInt (builtins.elemAt subnetParts 1);
  subnetBlockSize = pow2 (32 - subnetPrefix);
  addressInSubnet =
    address:
    let
      parsedAddress = parseIpv4 address;
    in
    parsedAddress != null
    && subnetAddress != null
    && builtins.div parsedAddress subnetBlockSize == builtins.div subnetAddress subnetBlockSize;

  workspaceSecrets = workspace: builtins.attrValues workspace.secrets;
  normalizeHosts = map lib.toLower;
  allowedSecretHosts =
    workspace: normalizeHosts (workspace.egress.httpHosts ++ workspace.egress.passthroughHosts);
  secretHosts =
    workspace: normalizeHosts (concatMap (secret: secret.hosts) (workspaceSecrets workspace));

  lifecycleRegistry = {
    version = 1;
    workspaces = mapAttrs (name: workspace: {
      inherit (workspace) hostname;
      inherit (workspace)
        runner
        network
        resources
        ssh
        ;
    }) cfg.workspaces;
  };

  registryFile = pkgs.writeText "seter-workspaces.json" (builtins.toJSON lifecycleRegistry);
in
{
  options.seter.host = {
    enable = mkEnableOption "the Seter micro-VM host";

    bridge = mkOption {
      type = types.strMatching "[a-zA-Z0-9_.-]{1,15}";
      default = "seter0";
      description = "Network bridge used by project VMs.";
    };

    subnet = mkOption {
      type = types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])";
      default = "10.100.0.0/24";
      description = "IPv4 subnet assigned to project VMs.";
    };

    workspaces = mkOption {
      type = types.attrsOf workspaceType;
      default = { };
      description = "Typed workspace registry used by the host and Seter CLI.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (name: builtins.match "[a-z0-9][a-z0-9-]{0,62}" name != null) (
          attrNames cfg.workspaces
        );
        message = "seter.host.workspaces names must contain only lower-case letters, digits, and hyphens";
      }
      {
        assertion = subnetAddress != null;
        message = "seter.host.subnet must start with a valid IPv4 address";
      }
      {
        assertion = lib.all (workspace: parseIpv4 workspace.network.address != null) workspaces;
        message = "seter.host.workspaces network addresses must be valid IPv4 addresses";
      }
      {
        assertion = lib.all (workspace: addressInSubnet workspace.network.address) workspaces;
        message = "seter.host.workspaces network addresses must belong to seter.host.subnet";
      }
      {
        assertion = hasUniqueValues (valuesFor (workspace: parseIpv4 workspace.network.address));
        message = "seter.host.workspaces must assign a unique IPv4 address to every workspace";
      }
      {
        assertion = hasUniqueValues (valuesFor (workspace: lib.toLower workspace.network.mac));
        message = "seter.host.workspaces must assign a unique MAC address to every workspace";
      }
      {
        assertion = hasUniqueValues (valuesFor (workspace: workspace.network.tap));
        message = "seter.host.workspaces must assign a unique tap interface to every workspace";
      }
      {
        assertion = hasUniqueValues (valuesFor (workspace: lib.toLower workspace.hostname));
        message = "seter.host.workspaces must assign a unique hostname to every workspace";
      }
    ]
    ++ concatMap (workspace: [
      {
        assertion = nonBlank workspace.runner.installable;
        message = "seter.host.workspaces.${workspace.name}.runner.installable must not be blank";
      }
      {
        assertion = workspace.ssh.knownHostKey == null || nonBlank workspace.ssh.knownHostKey;
        message = "seter.host.workspaces.${workspace.name}.ssh.knownHostKey must not be blank";
      }
      {
        assertion = lib.all (secret: nonBlank secret.placeholder) (workspaceSecrets workspace);
        message = "seter.host.workspaces.${workspace.name} secret placeholders must not be blank";
      }
      {
        assertion = lib.all (
          secret:
          !builtins.hasContext secret.sourceFile
          && secret.sourceFile != builtins.storeDir
          && !lib.hasPrefix "${builtins.storeDir}/" secret.sourceFile
        ) (workspaceSecrets workspace);
        message = "seter.host.workspaces.${workspace.name} secret source files must not reference the Nix store or carry Nix string context";
      }
      {
        assertion = lib.all (host: builtins.elem host (allowedSecretHosts workspace)) (
          secretHosts workspace
        );
        message = "seter.host.workspaces.${workspace.name} secret hosts must also be declared as HTTP or passthrough hosts";
      }
    ]) workspaces;

    environment.etc."seter/workspaces.json" = {
      source = registryFile;
      mode = "0444";
    };

    # Bridge, DNS, policy enforcement, and lifecycle services are deliberately
    # separate milestones. This module currently establishes their validated
    # registry contract only.
  };
}
