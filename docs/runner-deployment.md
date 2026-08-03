# Runner deployment

**Status:** implemented for the trusted `default` Guest Profile, including foundational storage and identity, Workspace Bootstrap, and daily lifecycle entry.

A Runner is trusted host infrastructure. It contains a workspace's selected Guest Profile and registered non-secret identity, but no project working tree or project development flake. Project code enters later through Workspace Bootstrap and builds inside the guest's private writable Nix store.

## Deployment contract

Trusted NixOS host deployment builds and roots the Runner for every registered default-profile workspace. A successful deployment atomically aligns:

- workspace identity and storage names;
- host-created Workspace SSH Identity;
- selected Guest Profile;
- host lifecycle units and resource controls;
- network and credential policy;
- the Runner used by the next cold boot.

`seter init` therefore requires a successfully deployed Runner but does not build one. `seter up`, `seter shell`, and `seter run` use the currently deployed Runner without evaluating Nix.

The default workflow has no `seter update`. Guest Profile or identity changes take effect through the consumer's normal trusted host deployment. Repository development-flake changes take effect inside the guest through normal Nix and direnv behavior.

## Trade-off

Host deployment may realize VM closures and take longer, especially when many workspace identities change together. This cost buys one deployment boundary: host units, expected identity, and boot artifacts cannot drift through a separate project-controlled update step. Shared Nix store paths still deduplicate common Guest Profile closures across workspaces.

Optimization must preserve this contract. Future evaluation could avoid rebuilding unchanged Runner outputs or deploy selected runners lazily from trusted derivations, but must not reintroduce project-owned host builds or stale host/runner identity.

## Platform VMM selection

`seter.host.runner.hypervisor` selects the trusted Host-wide Runner backend.
It defaults to `cloud-hypervisor`, preserving the native Linux path. The
`qemu` backend is the nested `aarch64-linux` path validated for the initial
macOS integration. On ARM it also enforces Linux 6.12 LTS on the Seter Host
and Workspace, KVM-only acceleration, headless console setup, and the QEMU
`fw_cfg` Workspace SSH Identity transport. The identity is loaded into each
VMM unit as a private systemd credential and staged root-only before OpenSSH;
the QEMU Runner has no identity virtiofs share.

The option is trusted host configuration, not a project or Workspace setting.
Changing it rebuilds and redeploys every Runner.

## Advanced runners

Specialized guest composition is outside the first milestone. If a future explicitly untrusted project-owned runner path is added, it may require a separate update mechanism and identity consistency checks. That future mechanism must not complicate or weaken the default trusted-profile workflow.
