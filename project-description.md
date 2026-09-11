# Seter architecture and threat model

Seter limits development workloads to one Workspace: one or more approved repositories,
shared persistent state, and explicitly granted authority. It aims to contain a
compromised dependency, hostile repository, or misbehaving coding agent without
requiring ordinary repositories to define their own guest operating system.

See the [README](./README.md) for current interfaces and the
[roadmap](./ROADMAP.md) for remaining product acceptance. This document describes
the implemented boundary, not speculative transparent macOS features.

## Trusted control plane

The NixOS Seter Host owns the Workspace Registry, Guest Profile, network policy,
credentials, storage, and lifecycle units. Trusted deployment builds and roots
an immutable Runner for every registered Workspace. Project code enters later
through HTTPS Workspace Bootstrap; it is not evaluated during Host deployment.

Cold starts validate the deployed identity manifest and start that Runner
without evaluating Nix. A narrow privileged CLI operation reloads Host-owned
state and controls a fixed unit; the VMM executes as a dedicated unprivileged
account with cgroup, device, and filesystem restrictions.

Consumer configuration owns users, repository sources, resource choices,
Policy Grants, and runtime secret sources. Repository development flakes and
`.envrc` files are untrusted workload input. They execute only inside the
Workspace, with explicit direnv approval. See
[configuration ownership](./docs/configuration-ownership.md).

## Workspace boundary

- Each Workspace has its own Linux kernel and KVM VM. Repositories inside it
  share user state and the union of its authority; there is no intra-Workspace
  repository isolation.
- Root is ephemeral. Separate Project, Home, and private Nix-store volumes
  retain working data, user configuration, and dependencies respectively.
- The lower store is an immutable EROFS image of the Runner's closure, not an
  ambient Host `/nix/store` export. Guest builds write only to the private
  upper store and their traffic crosses Workspace policy.
- No Host home, browser data, operator keys, SSH agent, X11 session, or other
  Workspace state is shared ambiently.
- The Host creates the Workspace SSH Identity. Client connections verify it
  strictly rather than trusting the first network-provided key.

`init`, `shell`, and `run` leave the Workspace running. `down` requests graceful
shutdown and waits for VMM exit, with bounded forced termination as a fallback.
Reset requires a stopped Workspace and can replace Home/private Store, never
Project data. Retirement retains Project data; destruction is separate and
strongly confirmed. See [storage lifecycle](./docs/storage-lifecycle.md).

## Network and credential authority

Host-owned nftables rules bind each Workspace to its registered TAP, IPv4, and
MAC identity. Cross-Workspace, ungranted Host/LAN, IPv6, and arbitrary UDP/ICMP
traffic are denied. A per-Workspace DNS frontend forwards canonical queries
only for granted names. Intercepted HTTP/HTTPS, TLS passthrough, exact direct
TCP, and explicit Host service relays have distinct policies.

Consumer-owned Policy Files are reviewed and deployed declaratively.
Observations never grant authority automatically. Wildcards match one DNS label
only, exclude the apex, and cannot bind credentials. See the
[network boundary](./docs/network-boundary.md).

For configured HTTP credentials, the guest holds a public placeholder. The
Host proxy loads real values from runtime credentials and substitutes them
only for the exact destination/header binding over verified HTTPS. Repository
credentials are additionally restricted to the approved Git smart-HTTP paths.

This keeps credential bytes outside the workload; it does not prevent malicious
code from exercising granted authority. Exact response redaction is hygiene,
not protection against a cooperating service encoding or disclosing secrets.
The shared proxy is trusted and holds the configured credentials for all
Workspaces. See [secret injection](./docs/secret-injection.md).

## macOS deployment

On macOS, a trusted aarch64-linux Seter Host runs under Lima/vz; Workspaces run
inside it through nested QEMU/KVM. The validated path uses Linux 6.12 LTS in
both Linux layers and fw_cfg/systemd credentials for Workspace SSH Identity.
Native Linux retains Cloud Hypervisor as its default.

The only Client share is an explicitly selected exchange directory available
to the Host, never the Workspace. All Workspace volumes live on the Host's
retained virtual disk. Operators enter the Host explicitly; attended agent
forwarding stops there. Client service access uses explicit loopback tunnels,
subject to the Workspace firewall. No tailnet, remote builder, automatic
launcher, or transparent routing is required. See
[macOS deployment](./docs/macos-deployment.md).

## Limits

- Compromised code can read, corrupt, or delete its own Project and Home data,
  and can exfiltrate through or misuse already-granted services.
- The Host kernel, VMM, Nix supply chain, and policy services remain trusted.
  Deliberate containment of VM-escape exploits is outside the threat model.
- Persistent guest state may remain compromised after a clean-root reboot;
  reset does not inspect or repair the Project Volume.
- Guest output still reaches the operator's terminal. VM isolation is not
  comprehensive terminal-output sanitization or malware detection.
- Fixed guest volumes and cgroups bound individual resources, but Host capacity
  planning, updates, backups, and credential rotation remain operator duties.
- TLS interception needs application trust-store integration; passthrough is
  destination-checked but opaque. Non-HTTP credential brokering is not provided.
- Broad macOS hardware coverage, unattended identity, automatic Host/tunnel
  management and additional Guest Profiles remain
  outside the current supported workflow.
