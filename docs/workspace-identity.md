# Generated workspace identity

`seter.lib.mkWorkspaceDefinition` turns one trusted workspace definition into two projections:

- `host` contains lifecycle settings, resource limits, egress policy, host-service authorization, and secret source paths;
- `guestModule` contains only the values required to build the matching guest.

The split prevents ordinary configuration drift without provisioning real credentials or host-only policy into the guest configuration or runner closure. It is not a source-code confidentiality boundary: a project that imports the infra flake can read every tracked file in that flake's source.

## Definition and flake wiring

In the trusted infra flake, define and register the workspace:

```nix
let
  project = seter.lib.mkWorkspaceDefinition {
    name = "project";
    runnerInstallable =
      "github:owner/project#nixosConfigurations.guest.config.microvm.declaredRunner";
    ip = "10.100.0.10";
    mac = "02:00:00:00:00:10";
    tap = "seter-project";

    # Set these when the host overrides Seter's defaults.
    gateway = "10.100.0.1";
    prefixLength = 24;
    proxyPort = 18081;
    nixStoreImage = "project-nix-store.img";
    nixStoreSizeMiB = 16384;
  };
in {
  nixosModules.projectIdentity = project.guestModule;

  nixosConfigurations.host = /* include:
    seter.host.workspaces.project = project.host;
  */;
}
```

The project flake imports the sanitized output:

```nix
modules = [
  seter.nixosModules.guest
  infra.nixosModules.projectIdentity
  ./guest.nix
];
```

Only use that direct import when projects are allowed to read the infra flake's complete source, including other tracked workspace policy and secret source paths. Nix flake outputs do not hide their input source. If those details are confidential, publish the generated identity module from a separate sanitized repository or flake containing only guest-visible definitions, and have both the host infra and project consume that source.

Keep the infra input revision deliberate and reviewed. A policy-only host change does not require rebuilding a guest, but an identity change does; `seter update` rejects a runner built against stale identity.

## Generated guest values

The guest module fixes:

- `seter.guest.name`;
- network enablement, IPv4 address, MAC address, TAP name, gateway, prefix, and gateway-only DNS;
- the explicit proxy URL;
- the SSH user;
- the project-volume image basename;
- the private Nix-store image basename and initial capacity.

Assertions also verify the effective microVM TAP, NixOS DNS and networkd wiring, proxy session variables, persistent project and Nix volumes, writable-store overlay, sandboxed guest Nix settings, SSH lifecycle access, configured placeholders, and proxy CA. This catches lower-level `lib.mkForce` overrides that leave the public `seter.guest` values unchanged.

It writes the public identity to `/etc/seter/workspace.json`. It also wraps `microvm.declaredRunner` with the same JSON at `share/seter/identity.json`. Assertions reject later overrides, including `lib.mkForce` overrides.

`proxyCaCertificate`, when supplied, is installed through the normal guest module. `secretVariables` maps guest environment names to host secret definitions, allowing several variables to share one placeholder without repeating it:

```nix
secretVariables = {
  GITHUB_TOKEN = "githubToken";
  GH_TOKEN = "githubToken";
};
```

An undefined secret name fails evaluation.

## Runner installation contract

The host writes registry version 4 and requires runner identity version 2 for generated definitions. Workspaces made with `mkWorkspaceDefinition` carry an expected runner identity derived from the host's effective gateway, subnet prefix, explicit proxy port, and workspace configuration.

Both the unprivileged and privileged halves of `seter update` parse the runner manifest without executing runner code. `seter up` repeats the comparison against the installed immutable runner before every cold start, catching host identity changes made after installation. Installation or startup fails if the manifest is absent, malformed, or differs from the root-owned registry. The comparison covers:

- manifest version and workspace name;
- host-visible workspace hostname;
- address, MAC, TAP, gateway, and prefix;
- proxy URL;
- SSH user;
- project image basename;
- private Nix-store image basename and initial capacity.

The manifest is runner-controlled consistency metadata, not cryptographic attestation. A deliberately modified workspace runner can write matching JSON while booting different code. Seter uses the comparison to catch stale or accidentally divergent generated configurations; host-side TAP identity checks, nftables policy, privilege separation, and resource controls remain authoritative for untrusted runners.

The old `lib.mkWorkspace` constructor remains a low-level compatibility interface. Its host entries do not require a runner manifest, so migrate security-sensitive workspaces to `mkWorkspaceDefinition` rather than using it for new definitions.

## Security boundary

The generated guest module and runner closure do not include:

- real secret values;
- secret source-file paths;
- HTTP, passthrough, or direct-TCP allowlists;
- other workspace definitions;
- host runtime accounts or service internals.

Placeholders and the proxy CA public certificate are intentionally non-secret and enter the Nix store. Importing an infra flake exposes its complete tracked source even when only one output is referenced. Keep confidential host definitions behind a real source boundary and publish guest modules from a separate sanitized source; otherwise treat the infra source, including host policy and runtime secret-file paths, as readable by every project that imports it.

## Migration

1. Replace `seter.lib.mkWorkspace { ... }` with `seter.lib.mkWorkspaceDefinition { name = "…"; ... }`.
2. Register `.host` under the same workspace name.
3. Export and import `.guestModule` in the project's guest configuration.
4. Remove duplicated guest name, address, MAC, TAP, gateway, proxy, SSH-user, project-image, and Nix-store settings.
5. Rebuild the project runner with `seter update`. A pre-migration runner is rejected because it has no identity manifest.
