# QEMU boundary review for macOS Workspaces

QEMU/KVM is the selected nested aarch64-linux backend. The conclusion combines
physical results summarized in [macOS validation](./macos-validation.md) with
the Host module and generated Runner invariants. It is functional equivalence
at Seter's boundary, not a claim of identical VMM implementations or attack
surfaces. Cloud Hypervisor remains the native-Linux default.

## Preserved contracts

| Property | QEMU implementation |
|---|---|
| Lifecycle | A fixed root-owned systemd unit runs the immutable Runner as the dedicated Workspace account. The Host requests `system_powerdown` through its private QMP socket and waits for VMM exit. |
| Isolation | Dedicated account, cgroup limits, filesystem hardening, device allowlist, and QEMU seccomp sandbox constrain the process. |
| Resources | Registered memory and vCPU count enter the trusted Runner; Host memory and CPU limits remain authoritative. |
| Storage | Separate raw Project, Home, and private Nix-store volumes attach as virtio block devices. Root remains ephemeral. |
| Store View | The Runner's read-only EROFS closure is below the private writable overlay; the ambient Host store is not shared. |
| SSH identity | The Host-created server key enters the VMM unit through a private systemd credential and reaches the guest through fw_cfg. A required root-only staging service runs before sshd. Key bytes are absent from the Nix store and command line. |
| Networking | The Host creates the exact registered TAP, MAC, and address binding, with queue count matching vCPUs. |
| Policy | Host nftables, DNS, proxy, and relay services enforce authority independently of the VMM. Selecting QEMU grants no additional destinations or Host services. |
| Cleanup | The same runtime target, TAP ownership, lifecycle locks, and stopped-only reset rules apply. A missing main PID is already stopped; a missing QMP socket while the VMM lives is a shutdown error, not success. |

## Trade-offs and constraints

QEMU has a larger device-model attack surface and closure than Cloud
Hypervisor. Its selection does not authorize extra devices, TCG fallback,
broader Host paths, or weaker network/systemd controls.

Both Linux layers are pinned to Linux 6.12 LTS. Full NixOS testing, rather than
minimal guest boot success, established this requirement. Dependency changes
need renewed physical validation.

The identity virtiofs share was functionally available but caused excessive
startup latency on the tested nested ARM device path. fw_cfg avoids that
share and its associated PCI/shared-memory configuration. Native Cloud
Hypervisor keeps its existing read-only identity virtiofs transport.

The unprivileged Workspace user cannot read either the raw fw_cfg key or the
staged private key. Guest root and the VMM can necessarily observe the server
key used inside their VM; this does not give them another Workspace's identity
or the operator's login key. The Host remains the identity's creator and
persistence owner.

Shutdown is bounded by systemd's timeout and forced termination fallback.
Clean persistence requires guest unmounts and VMM exit, not merely waiting for
that timeout. See the [regression checklist](./macos-testing.md).

Early performance samples are not a distribution or a broad support promise.
Repeat representative workloads and reproduce on another eligible Mac before
making stronger operability claims.
