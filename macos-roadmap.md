# macOS integration roadmap

## Status and scope

The manual nested deployment and operator path has been validated on an
**M5 Mac**. The complete-workflow and operability gates remain open; this is
not broad macOS support or an automated native macOS client.

- [Deployment](./docs/macos-deployment.md): bootstrap, consumer configuration,
  remote builds, retained storage, and recovery boundaries.
- [Operator workflow](./docs/macos-workflow.md): terminal entry, attended
  authentication, policy review, and loopback tunnels.
- [Validation summary](./docs/macos-validation.md): established behavior and
  limits, without machine-specific evidence.
- [Validation checklist](./docs/macos-testing.md): repeatable product checks.

Nested virtualization requires Apple Silicon M3 or newer and macOS 15 or newer.
The wrapper currently recognizes M3, M4, and M5; physical validation covers
only an M5 Mac. Intel, M1/M2, older macOS, and software-emulated fallback are
unsupported. One trusted Seter Host serves one macOS Client.

## Architecture

```text
macOS Client: Nix, Lima, consumer flake, selected exchange directory
    |
    v
Seter Host: aarch64-linux NixOS under Lima/vz
    |      trusted Registry, policy, credentials, CLI, persistent storage
    v
Workspace: nested QEMU/KVM, repository, private development state
```

The Seter Host is trusted, not another untrusted workload. The Client Exchange
Directory is its only explicit macOS share and is never mounted into a
Workspace. Project, Home, and private Nix-store volumes stay on its virtual
disk. The consumer owns users, Registry entries, Policy Grants, resource
allocations, and secret sources; the reusable module owns no site identity.

The accepted path pins Linux 6.12 LTS in both Linux layers and uses QEMU/KVM
with fw_cfg/systemd credentials for Workspace SSH Identity. See
[ADR 0009](./docs/adr/0009-use-qemu-for-macos-workspaces.md),
[ADR 0010](./docs/adr/0010-use-fw-cfg-for-macos-workspace-ssh-identity.md), and
[QEMU boundary review](./docs/macos-qemu-equivalence.md). Native Linux retains
Cloud Hypervisor as its default.

## Completed foundations

1. Nested full-NixOS feasibility with networking and persistent storage.
2. ARM CLI/Host/Guest/Runner builds and ordinary product lifecycle; native
   x86_64 regression coverage retained.
3. Pinned Lima template, reusable `limaHost` module, external consumer example,
   Client-side evaluation with Host-side Linux builds, repeat deployment,
   fresh bootstrap-key login, graceful QMP shutdown, and retained state.
4. Manual terminal and attended-agent workflow, policy review/redeployment
   through the exchange directory, and loopback-only tunnel boundary checks.

These correspond to the original phases 1–4. Their results do not imply the
following gates have passed.

The current atomic bootstrap-key publication and existing-mount source, type,
and read-write validation were added after those physical results. Their
synthetic Linux checks pass, but a physical deployment, retained-Host cold boot,
and repeat deployment remain required.

## Remaining: complete-workflow acceptance

Run one coherent acceptance sequence through the public interface:

- deploy the trusted default-profile Runner;
- initialize an authenticated HTTPS repository and verify strict SSH identity
  and filtered Store View;
- observe denial, review a declarative grant, deploy, and verify policy agrees;
- explicitly approve direnv, use interactive `shell` and non-interactive `run`;
- fetch and push the approved repository without exposing its credential;
- reach a permitted Workspace development service from a Client browser over
  a loopback-only tunnel;
- verify exact Project/Home/private Store persistence after Workspace restart,
  retained-Host stop/start, consumer redeployment, and macOS reboot;
- reset reproducible state without touching Project data, then stop and retire
  safely.

Add a maintained acceptance script for repeatable portions of this product
sequence, not a parallel diagnostic VM implementation. Physical runtime testing
remains a manual gate; Linux evaluation cannot replace it.

## Remaining: operability and reproducibility

Measure cold startup, authenticated shell entry, a representative build, and
filesystem I/O with repeated samples and documented methodology. Reproduce on
another eligible Mac before broadening support. Publish generalized outcomes,
not raw machine inventories or site configuration. Only “M5 Mac” is retained
as tested-machine information.

The milestone is complete only when a clean eligible Client can follow the
checked-in procedure, all workflow gates pass, normal development is practical,
and native NixOS checks still pass. A running Workspace need not resume after
an outer restart; a clean stopped state with retained volumes is sufficient.

## Non-goals and later work

The first integration has no Darwin Seter CLI, automatic Lima provisioning or
startup, automatic tunnels, direct/subnet routing, Tailscale integration, USB
passthrough, broad home sharing, multi-Host management, backup/restore, or
recovery from deletion/corruption. No separate Linux builder is required.

The attended SSH-agent bridge trusts the Seter Host for that connection and
must not forward the agent into a Workspace. It is not an unattended identity
solution. A purpose-built operator identity and a native client may follow
once the manual workflow is stable. Managed launch, routing, and backups must
preserve the same isolation and consumer-ownership boundaries.
