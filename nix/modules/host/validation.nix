# Host invariants, including the Policy File's strict input schema.
{
  cfg,
  lib,
  pkgs,
  config,
  workspaces,
  workspaceRuntime,
  policyRaw,
  policyWorkspaces,
  parseIpv4,
  subnetPrefix,
}:
let
  inherit (lib) attrNames concatMap unique;
  hostPatterns = import ./host-patterns.nix { inherit lib; };
  policyEgressFor = value: value.egress or { };
  hasOnlyAttrs =
    allowed: value:
    builtins.isAttrs value && lib.all (name: builtins.elem name allowed) (attrNames value);
  policyStructureValid =
    hasOnlyAttrs [ "version" "workspaces" ] policyRaw
    && builtins.isAttrs policyWorkspaces
    && lib.all (
      value:
      hasOnlyAttrs [ "egress" ] value
      && hasOnlyAttrs [ "http-hosts" "passthrough-hosts" "tcp" ] (policyEgressFor value)
      && lib.all (destination: hasOnlyAttrs [ "host" "port" ] destination) (
        (policyEgressFor value).tcp or [ ]
      )
    ) (builtins.attrValues policyWorkspaces);
  valuesFor = select: map select workspaces;
  hasUniqueValues = values: builtins.length values == builtins.length (unique values);

  pow2 = exponent: if exponent == 0 then 1 else 2 * pow2 (exponent - 1);
  subnetParts = lib.splitString "/" cfg.subnet;
  subnetAddress = parseIpv4 (builtins.elemAt subnetParts 0);
  subnetBlockSize = pow2 (32 - subnetPrefix);
  subnetNetwork =
    if subnetAddress == null then
      null
    else
      builtins.div subnetAddress subnetBlockSize * subnetBlockSize;
  subnetBroadcast = if subnetNetwork == null then null else subnetNetwork + subnetBlockSize - 1;
  gatewayAddress = parseIpv4 cfg.gateway;
  addressInSubnet =
    address:
    let
      parsedAddress = parseIpv4 address;
    in
    parsedAddress != null
    && subnetAddress != null
    && builtins.div parsedAddress subnetBlockSize == builtins.div subnetAddress subnetBlockSize;

  addressIsUsable =
    address:
    let
      parsedAddress = parseIpv4 address;
    in
    parsedAddress != null
    && addressInSubnet address
    && parsedAddress != subnetNetwork
    && parsedAddress != subnetBroadcast;

  workspaceSecretNames = workspace: attrNames workspace.secrets;
  workspaceSecrets = workspace: builtins.attrValues workspace.secrets;
  normalizeHosts = map lib.toLower;
  normalizeHeaders = map lib.toLower;
  validSecretName = name: builtins.match "[a-zA-Z][a-zA-Z0-9_-]{0,62}" name != null;
  validSecretPlaceholder =
    placeholder: builtins.match "seter-placeholder-[a-zA-Z0-9_-]{16,}" placeholder != null;
  nonOverlappingPlaceholders =
    placeholders:
    lib.all (
      placeholder: lib.all (other: placeholder == other || !lib.hasInfix placeholder other) placeholders
    ) placeholders;
  prohibitedSecretHeaders = [
    "connection"
    "content-length"
    "host"
    "keep-alive"
    "proxy-authenticate"
    "proxy-authorization"
    "proxy-connection"
    "te"
    "trailer"
    "transfer-encoding"
    "upgrade"
  ];
  allowedSecretHosts =
    workspace: normalizeHosts (repositories.hosts workspace ++ workspace.egress.httpHosts);
  secretHosts =
    workspace: normalizeHosts (concatMap (secret: secret.hosts) (workspaceSecrets workspace));

  repositories = import ../../lib/repositories.nix { inherit lib; };
  repositoryValues = workspace: builtins.attrValues workspace.resolvedRepositories;
  validRepositoryPath =
    path:
    let
      lower = lib.toLower path;
      components = lib.drop 1 (lib.splitString "/" path);
    in
    lib.all (component: component != "" && component != "." && component != "..") components
    && !lib.hasInfix "%2e" lower
    && !lib.hasInfix "%2f" lower
    && !lib.hasInfix "%5c" lower;

in
{
  assertions = [
    {
      assertion =
        cfg.runner.hypervisor != "qemu"
        || !pkgs.stdenv.hostPlatform.isAarch64
        || config.boot.kernelPackages.kernel == pkgs.linuxPackages_6_12.kernel;
      message = "the aarch64-linux QEMU Seter Host requires the validated Linux 6.12 LTS kernel";
    }
    {
      assertion = (policyRaw.version or null) == 1;
      message = "seter.host.policyFile must use Policy File version 1";
    }
    {
      assertion = policyStructureValid;
      message = "seter.host.policyFile contains unknown fields or invalid table structure";
    }
    {
      assertion = lib.all (name: builtins.hasAttr name cfg.workspaces) (attrNames policyWorkspaces);
      message = "seter.host.policyFile must not refer to an unknown workspace";
    }
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
      assertion = subnetPrefix <= 30;
      message = "seter.host.subnet must leave room for a gateway and at least one workspace";
    }
    {
      assertion = gatewayAddress != null && addressIsUsable cfg.gateway;
      message = "seter.host.gateway must be a usable IPv4 address in seter.host.subnet";
    }
    {
      assertion = lib.all (workspace: parseIpv4 workspace.network.address != null) workspaces;
      message = "seter.host.workspaces network addresses must be valid IPv4 addresses";
    }
    {
      assertion = lib.all (workspace: addressIsUsable workspace.network.address) workspaces;
      message = "seter.host.workspaces network addresses must be usable addresses in seter.host.subnet";
    }
    {
      assertion = lib.all (workspace: parseIpv4 workspace.network.address != gatewayAddress) workspaces;
      message = "seter.host.workspaces network addresses must not reuse seter.host.gateway";
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
      assertion = lib.all (workspace: workspace.network.tap != cfg.bridge) workspaces;
      message = "seter.host.workspaces tap interfaces must not reuse seter.host.bridge";
    }
    {
      assertion = hasUniqueValues (valuesFor (workspace: lib.toLower workspace.hostname));
      message = "seter.host.workspaces must assign a unique hostname to every workspace";
    }
    {
      assertion = lib.all (runtime: runtime.account != cfg.operatorGroup) (
        builtins.attrValues workspaceRuntime
      );
      message = "seter.host.operatorGroup must not collide with a workspace runtime account";
    }
  ]
  ++ concatMap (workspace: [
    {
      assertion = lib.all hostPatterns.valid (
        workspace.egress.httpHosts ++ workspace.egress.passthroughHosts
      );
      message = "seter.host.workspaces.${workspace.name} HTTP and passthrough grants must be exact lower-case hosts or safe single-label Host Patterns";
    }
    {
      assertion =
        hasUniqueValues (normalizeHosts workspace.egress.httpHosts)
        && hasUniqueValues (normalizeHosts workspace.egress.passthroughHosts)
        && hasUniqueValues (
          map (
            destination: "${lib.toLower destination.host}:${toString destination.port}"
          ) workspace.egress.tcp
        );
      message = "seter.host.workspaces.${workspace.name} Policy Grants must not contain duplicates";
    }
    {
      assertion = lib.all (
        http:
        lib.all (
          passthrough: !(hostPatterns.overlaps (lib.toLower http) (lib.toLower passthrough))
        ) workspace.egress.passthroughHosts
      ) workspace.egress.httpHosts;
      message = "seter.host.workspaces.${workspace.name} intercepted HTTP and TLS passthrough Host Patterns must not overlap";
    }
    {
      assertion = workspace.repository == null || workspace.repositories == { };
      message = "seter.host.workspaces.${workspace.name} cannot combine repository and repositories";
    }
    {
      assertion = workspace.resolvedRepositories != { };
      message = "seter.host.workspaces.${workspace.name} requires at least one repository";
    }
    {
      assertion =
        lib.all repositories.validName (attrNames workspace.resolvedRepositories)
        && lib.all (repository: repositories.validName repository.checkoutName) (
          repositoryValues workspace
        );
      message = "seter.host.workspaces.${workspace.name} repository and checkout names must start with a letter or digit and contain only letters, digits, underscores, dots, or hyphens";
    }
    {
      assertion = hasUniqueValues (
        map (repository: repository.checkoutName) (repositoryValues workspace)
      );
      message = "seter.host.workspaces.${workspace.name} repositories must use unique checkout names";
    }
    {
      assertion =
        workspace.defaultRepository == null
        || builtins.hasAttr workspace.defaultRepository workspace.resolvedRepositories;
      message = "seter.host.workspaces.${workspace.name} defaultRepository must name a registered repository";
    }
    {
      assertion = lib.all (repository: repositories.match repository != null) (
        repositoryValues workspace
      );
      message = "seter.host.workspaces.${workspace.name} repository URL must use HTTPS on port 443 and contain an exact path";
    }
    {
      assertion = lib.all (repository: validRepositoryPath (repositories.path repository)) (
        repositoryValues workspace
      );
      message = "seter.host.workspaces.${workspace.name} repository URL path must not contain empty, dot, or encoded separator segments";
    }
    {
      assertion = lib.all (
        repository:
        repository.credential == null || builtins.hasAttr repository.credential workspace.secrets
      ) (repositoryValues workspace);
      message = "seter.host.workspaces.${workspace.name} repository credential must reference a defined secret";
    }
    {
      assertion = lib.all (
        repository:
        repository.credential == null
        || (
          builtins.hasAttr repository.credential workspace.secrets
          && builtins.elem (repositories.host repository) (
            normalizeHosts workspace.secrets.${repository.credential}.hosts
          )
          && builtins.elem "authorization" (
            normalizeHeaders workspace.secrets.${repository.credential}.headers
          )
        )
      ) (repositoryValues workspace);
      message = "seter.host.workspaces.${workspace.name} repository credential must allow the repository's exact host and authorization header";
    }
    {
      assertion =
        workspace.repository != null
        || lib.all (
          repository:
          repository.credential == null
          || (
            builtins.hasAttr repository.credential workspace.secrets
            && workspace.secrets.${repository.credential}.repositoryOnly
          )
        ) (repositoryValues workspace);
      message = "seter.host.workspaces.${workspace.name} repositories require repositoryOnly = true on their credential bindings (safe revocation after repository removal)";
    }
    {
      assertion = lib.all (secretName: builtins.hasAttr secretName workspace.secrets) (
        builtins.attrValues workspace.secretVariables
      );
      message = "seter.host.workspaces.${workspace.name} secret variables must reference defined secrets";
    }
    {
      assertion = hasUniqueValues [
        workspace.storage.project.image
        workspace.storage.home.image
        workspace.storage.nixStore.image
      ];
      message = "seter.host.workspaces.${workspace.name} volume images must use distinct names";
    }
    {
      assertion = hasUniqueValues workspace.hostServices;
      message = "seter.host.workspaces.${workspace.name}.hostServices must not contain duplicates";
    }
    {
      assertion = lib.all validSecretName (workspaceSecretNames workspace);
      message = "seter.host.workspaces.${workspace.name} secret names must start with a letter and contain only letters, digits, underscores, or hyphens, up to 63 characters";
    }
    {
      assertion = lib.all (secret: validSecretPlaceholder secret.placeholder) (
        workspaceSecrets workspace
      );
      message = "seter.host.workspaces.${workspace.name} secret placeholders must start with seter-placeholder- and have a URL-safe suffix of at least 16 characters";
    }
    {
      assertion = hasUniqueValues (map (secret: secret.placeholder) (workspaceSecrets workspace));
      message = "seter.host.workspaces.${workspace.name} secret placeholders must be unique within the workspace";
    }
    {
      assertion = nonOverlappingPlaceholders (
        map (secret: secret.placeholder) (workspaceSecrets workspace)
      );
      message = "seter.host.workspaces.${workspace.name} secret placeholders must not contain one another";
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
      message = "seter.host.workspaces.${workspace.name} secret hosts must be declared as intercepted HTTP hosts; TLS passthrough cannot inject secrets";
    }
    {
      assertion = lib.all (secret: hasUniqueValues (normalizeHosts secret.hosts)) (
        workspaceSecrets workspace
      );
      message = "seter.host.workspaces.${workspace.name} secret host lists must not contain case-insensitive duplicates";
    }
    {
      assertion = lib.all (secret: hasUniqueValues (normalizeHeaders secret.headers)) (
        workspaceSecrets workspace
      );
      message = "seter.host.workspaces.${workspace.name} secret header lists must not contain case-insensitive duplicates";
    }
    {
      assertion = lib.all (
        secret: lib.intersectLists (normalizeHeaders secret.headers) prohibitedSecretHeaders == [ ]
      ) (workspaceSecrets workspace);
      message = "seter.host.workspaces.${workspace.name} secret headers must not include routing, framing, hop-by-hop, or proxy authentication headers";
    }
  ]) workspaces;

}
