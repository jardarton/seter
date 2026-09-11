# macOS validation status

## Scope

Manual physical testing on an **M5 Mac** established the nested QEMU/KVM
deployment and operator path. This is a summary of supplied acceptance results,
not a claim that Linux CI reproduces macOS behavior or that all eligible Macs
have been tested. The complete-workflow and operability gates in the
[roadmap](../macos-roadmap.md) remain open.

The validated stack used Lima/vz, the pinned nixos-lima bootstrap, QEMU/KVM,
Linux 6.12 LTS in both Linux layers, and a four-vCPU Workspace. Dependency
revisions are controlled by `flake.lock` and the image digest in
`lima/seter.yaml`; updates require renewed physical validation.

Atomic bootstrap-key publication and existing-mount source, type, and
read-write validation were added after the physical results below. They
currently have synthetic Linux coverage only and still require a physical Mac
deployment, retained-Host cold boot, and repeat-deployment rerun.

## Established behavior

| Area | Physical result |
|---|---|
| Nested virtualization | Full NixOS Workspace boot, assigned vCPUs, KVM, TAP networking, DNS, and approved HTTPS worked. |
| ARM product path | CLI, Host, Guest, Registry, and generated Runner builds passed; ordinary initialization, shell, run, and stop worked. |
| SSH identity | Strict verification matched the Host-created key; substituted keys were rejected. The guest user could not read staged or raw fw_cfg private-key data. |
| Isolation | Unrelated Host store content was absent, ungranted egress was denied, and the operator agent was not forwarded into the Workspace. |
| Deployment | Repeat deployment and retained-Host cold boot preserved fresh bootstrap-key SSH access, independently of connection sharing. |
| Shutdown and storage | QMP powerdown completed successfully; guest unmounts preceded VMM exit. Newly written Project, Home, and private Store markers survived byte-for-byte without an explicit guest `sync`. |
| Operator terminal | Interactive TTY, Ctrl-C, and command/shell exit-status propagation worked through both SSH hops. |
| Policy workflow | Review edited the consumer Policy File through the exchange directory; trusted redeployment changed pending policy to desired/active agreement. |
| Exchange mount | Read-write access survived repeat deployment and retained-Host stop/start. The directory was not exposed to the Workspace. |
| Tunnel boundary | A loopback-only tunnel reached the registered Workspace SSH endpoint; a port not permitted by the Guest Profile remained blocked. This is not evidence of a browser-based development service workflow. |

Native x86_64 Linux regression checks also passed after integration, retaining
Cloud Hypervisor and its read-only identity transport. They complement, rather
than replace, the physical results above.

## Lessons retained in the implementation

- Pin Linux 6.12 LTS in both layers. Minimal guest boots did not predict full
  NixOS reliability on the bootstrap's newer kernel.
- Use QEMU/KVM for this nested path. Cloud Hypervisor did not pass the physical
  reliability gate; software emulation is not a supported fallback.
- Deliver Workspace SSH Identity through fw_cfg/systemd credentials. Adding
  the identity virtiofs device caused excessive startup latency on this stack.
- Use QMP `system_powerdown`, not keyboard emulation, and wait for VMM exit.
  Headless ARM QEMU rejected Ctrl-Alt-Delete; waiting for a timeout alone did
  not establish graceful shutdown or safe persistence.
- Preserve bootstrap authorization from immutable Lima cidata during both
  activation and boot. A working shared SSH connection can conceal a broken
  fresh-login path.
- Re-establish the exchange mount after NixOS activation removes Lima's
  boot-generated mount unit.
- Keep the proxy bounded but allow sufficient memory for parallel binary-cache
  transfers; the previous fixed cap caused OOM failures.

## Not yet established

The tests do not establish broad hardware support, a performance distribution,
recovery from disk corruption/deletion, or the full authenticated repository,
browser tunnel, reset/retirement, and macOS-reboot workflow as one acceptance
sequence. Early timing samples show usable startup but are not performance
guarantees. Repeat representative measurements before publishing expectations.

Use the [validation checklist](./macos-testing.md) for future changes. Keep raw
logs, keys, certificates, fingerprints, filesystem UUIDs, mount tags, account
names, addresses, and machine inventories private. Public reports should
contain generalized outcomes and only “M5 Mac” as tested-machine information.
