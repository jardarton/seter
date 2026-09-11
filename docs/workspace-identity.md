# Workspace and Runner identity

The trusted `seter.host.workspaces` option is the single Workspace Registry schema. A registry entry contains the named collection of approved HTTPS repositories and optional default repository, selected Guest Profile, network identity, resource limits, SSH settings, persistent-volume settings, credential bindings, and effective host policy.

The host module derives three artifacts from the same evaluated entry:

1. host enforcement and lifecycle units;
2. the version-7 registry at `/etc/seter/workspaces.json`;
3. a trusted default-profile Runner at `/etc/seter/runners/<workspace>`.

There is no public workspace constructor, project Runner installable, or `seter update` path. Repository code is not evaluated while building the Runner.

## Runner identity manifest

Each Runner contains a regular immutable `share/seter/identity.json` file. The registry records the expected manifest and its schema version; the CLI rejects unsupported versions. It covers:

- workspace name and hostname;
- IPv4 address, MAC address, TAP, gateway, and prefix;
- explicit proxy URL;
- SSH user;
- selected Guest Profile;
- guest memory and vCPU count;
- Project, Home, and private Nix-store volume names and capacities.

The generated guest module also asserts the effective microVM interface, networkd wiring, proxy variables, project and Nix-store volumes, writable-store overlay, Nix safety settings, SSH service, public proxy CA, and non-secret placeholders. This catches accidental lower-level drift during trusted evaluation.

Before every cold start, `seter` parses the bounded regular-file manifest without executing Runner code and compares it with the root-owned registry. A mismatch fails before systemd starts the VM. This check performs no Nix evaluation or build.

The manifest is consistency metadata, not cryptographic attestation. Host-owned TAP, nftables, resource controls, and lifecycle privilege separation remain authoritative.

Repository collection and default-selection changes belong to the lifecycle
registry, not the Runner identity manifest. They do not inherently require new
VM identity or storage. The manifest remains version 3; the lifecycle registry
uses version 7. See [multi-repository workspaces](./multi-repository-workspaces.md).

## Deployment and rooting

Every Runner is an explicit dependency of the NixOS system closure and the source of `/etc/seter/runners/<workspace>`. The registry and systemd service refer to that same store path. NixOS generation activation therefore publishes host policy, lifecycle units, and Runner together; previous system generations retain their corresponding Runner closures for rollback.

See [Runner deployment](./runner-deployment.md) and [Configuration ownership](./configuration-ownership.md).
