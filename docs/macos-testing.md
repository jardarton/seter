# Validating the macOS path

Use the ordinary [deployment](./macos-deployment.md) and
[operator workflow](./macos-workflow.md), with a disposable Workspace and
consumer-owned configuration. Do not maintain a second diagnostic Host or
guest implementation in Seter merely to obtain a passing boot.

**Do not run NixOS VM tests inside Lima:** those tests boot their own Host
before booting a Workspace, introducing an unintended third virtualization
layer. Run ARM build checks in the Seter Host and the product lifecycle
directly through its Seter CLI. Run native VM regressions on x86_64 Linux.

## Automated checks

On native x86_64 Linux, from the development shell:

```sh
cargo test
cargo clippy
nix build .#seter
nix flake check
```

Do not use `--all-systems`. The native flake check covers the existing KVM
lifecycle/network/storage boundary and Lima configuration checks, not the
physical macOS runtime. Use `scripts/run-captured` for verbose builds.

Synthetic helper tests cover cidata parsing, repeat/failed key publication,
and rejection of wrong-source, wrong-type, or read-only exchange mounts. They
do not exercise Lima activation or actual virtiofs mounting; repeat the physical
deployment/cold-boot checks when changing these helpers.

On the aarch64-linux Seter Host, build from an explicitly supplied Seter source
checkout outside any Workspace:

```sh
nix build \
  .#checks.aarch64-linux.seter \
  .#checks.aarch64-linux.nixos-host-module \
  .#checks.aarch64-linux.nixos-guest-module \
  .#checks.aarch64-linux.workspace-registry \
  .#checks.aarch64-linux.workspace-uniqueness \
  .#checks.aarch64-linux.arm-qemu-runner
nix flake check
```

While testing intentionally untracked source files, `path:.` includes the full
source whereas a Git flake excludes them. Do not publish its source snapshots
or logs without reviewing them for local data.

## Physical regression checklist

1. **Bootstrap:** create from the pinned template with exactly one selected
   exchange directory; deploy the consumer flake with Linux builds performed
   on the Seter Host. Do not rely on a separate remote builder.
2. **Kernel and Runner:** verify aarch64 and Linux 6.12 LTS in both layers,
   KVM-only acceleration, declared vCPUs, dedicated VMM account, cgroup limits,
   exact TAP binding, and no identity virtiofs device on the ARM QEMU path.
3. **Authorization:** test fresh SSH with connection sharing disabled after
   initial deployment, repeat deployment, retained-Host cold boot, and another
   deployment. Check root ownership and modes of projected bootstrap keys.
4. **Repository:** initialize the approved HTTPS repository, retry safely, and
   verify strict Workspace SSH Identity. For complete-workflow acceptance,
   use repository-scoped credential injection and test fetch and push without
   exposing the credential or granting sibling-repository authority.
5. **Guest boundary:** confirm tmpfs root, separate Project/Home/private Store
   volumes, filtered Store View, unreadable staged and raw identity credentials,
   rejection of a substituted SSH host key, and no guest `SSH_AUTH_SOCK`.
6. **Terminal:** test attended agent authentication through a fresh Host SSH
   connection, interactive TTY, Ctrl-C, shell exit status, and `run` exit status.
   Review `.envrc` before explicitly approving direnv.
7. **Policy and exchange:** trigger an ungranted request; review one narrow
   grant through the consumer Policy File; compare bytes on the Client; deploy
   and confirm desired/active agreement. Recheck read-write exchange access
   after each deployment and retained-Host restart.
8. **Tunnel:** bind explicitly to Client loopback. Verify the registered SSH
   identity through a tunnel; separately test a browser development service on
   a port permitted by the trusted Guest Profile. Confirm an unpermitted port
   remains unreachable and the tunnel is not listening on other interfaces.
9. **Shutdown:** write new marker content to all three persistent volumes,
   then use ordinary `seter down` without an explicit `sync`. Require guest
   unmounts before VMM exit, successful service teardown rather than a timeout,
   TAP/runtime-credential cleanup, and exact marker contents after restart.
10. **Outer persistence:** repeat marker checks after retained-Host stop/start,
    trusted redeployment, and a macOS reboot followed by manual Host startup.
    Compare disk identity locally; do not publish the identifier.
11. **Reset and retirement:** with disposable data, confirm stopped-only reset
    preserves Project content and Workspace SSH Identity. Retire the Workspace
    and confirm retained Project data is not silently deleted.

A surviving marker alone is not proof of graceful shutdown: delayed writeback
before a forced VMM termination can mask a broken stop path. Conversely, a
port-22 connection alone is not proof of authenticated Workspace readiness.

## Operability measurements

Measure Host startup, Workspace launch-to-authenticated-SSH, shell entry,
a representative offline Nix or Rust build, and filesystem I/O. Compare the
same fixed amount of work on the Seter Host and nested Workspace; a
fixed-duration CPU benchmark cannot measure completion-time overhead.

Use several runs, distinguish warm caches from cold starts, and report
variability rather than a single precise timing. The comparison measures the
marginal Workspace layer, not bare-metal performance. Unrealistically slow
startup or unstable disk I/O blocks operability even when a functional check
eventually passes.

## Reporting and safety

Keep raw evidence outside the repository. Publish only the test scope, outcome,
generalized defect, relevant dependency constraints, and remaining gaps. The
only tested-machine description retained publicly is **M5 Mac**. Do not include
actual user/host names, IP/MAC addresses, private paths, machine inventories,
UUIDs, share tags, key material, certificates, fingerprints, or raw logs.

Use a dedicated test identity whose private half stays on the Client. Remove
it from the agent when finished. Stop Workspaces before stopping the Host.
`limactl stop` retains the disk; `limactl delete` destroys it and every Workspace
volume. Never use deletion or image replacement as a routine test retry.
