# Seter - Project VMs — Isolated, Nix-Managed Development Environments

## Intention

Run every development project inside its own on-demand Linux micro-VM, defined and managed entirely with Nix, on both NixOS hosts and macOS. Each VM is a hard isolation boundary with controlled network egress, no direct access to secrets, and explicit, minimal bridges back to the host. The same project definition serves two modes: ephemeral ("boot, run a command, discard") and long-lived interactive development.

## Motivation

Modern development runs large amounts of code the developer never reviews: dependency install scripts, build plugins, and increasingly, code written and executed by AI agents. That code typically runs with the developer's full user privileges — able to read SSH keys, cloud credentials, browser data, and every other project on the machine, and to send anything it finds anywhere on the internet.

The goal of this project is to limit the blast radius of a compromised dependency, a malicious repo, or a misbehaving agent to the single project it runs in:

- **Isolation by default.** A project VM can see its own working tree and its own persistent state. Nothing else.
- **No real secrets in the guest.** Credentials are injected at the network edge by the host, bound to specific destinations. The guest only ever holds placeholders.
- **Egress is allowlisted, per project.** Code in a VM can reach the hosts its project legitimately needs, and nothing else. All traffic is observable.
- **Nix everywhere.** Guest images, dev environments, network policy, and secret bindings are all declarative, reproducible, and reviewed in version control. Dependency management inside the VMs is plain Nix flakes with direnv, same as on a bare host.
- **Cheap enough to actually use.** VMs boot in seconds by sharing the host Nix store, so isolation does not compete with convenience.

Existing tools cover parts of this (micro-VM runners, agent sandboxes with egress control, general-purpose VM managers), but none combine Nix-native guest definitions, per-project network policy with secret injection, host-store sharing, and a uniform experience across NixOS and macOS hosts. This project is the glue that combines mature components into that whole.

## Solution Outline

### Layers

1. **VM layer** — [microvm.nix](https://github.com/astro/microvm.nix) with cloud-hypervisor (or QEMU) on NixOS hosts. Guests are NixOS configurations exported from each project's flake. The host `/nix/store` is shared read-only into guests via virtiofs, so guests are small and boot fast.
2. **Policy layer** — all guest egress is default-denied by nftables on the host bridge and forced through a host-side mitmproxy running a Python policy addon: per-project host allowlists, placeholder→real secret injection for bound destinations, SNI passthrough for cert-pinned or bulk hosts, and full request audit logging.
3. **Host integration layer** — a small launcher CLI (`vm`) that builds, starts, stops, and executes into VMs; generated host DNS entries; forwarded host-side device daemons (e.g. an adb server) instead of USB passthrough; direnv integration on both sides of the boundary.

### macOS support via nested virtualization

macOS hosts do not run micro-VMs directly. Instead, one large, long-lived NixOS VM runs under Lima using the `vz` backend with `nestedVirtualization: true` (requires Apple Silicon M3 or newer and macOS 15+). Inside it, the exact same stack runs as on native NixOS hosts: same launcher, same microvm.nix definitions, same proxy, same policy. The outer VM is pure infrastructure — projects run in inner micro-VMs, working trees live on the outer VM's disk (never on macOS-shared paths), and the outer VM joins the tailnet as a first-class node. This trades a modest nested-virtualization performance cost for having exactly one boot path and one policy implementation across all machines.

### Definitions live in two places

The unit of isolation is a **workspace** — usually one repo, but possibly several coupled ones (see "Multi-repo workspaces" below).

- **Workspace flake**: exports the guest NixOS configuration — packages, services, Docker if needed — and imports a shared base module (proxy CA trust, store mount, serial console, guest conventions). For single-repo workspaces it lives in the repo itself; for multi-repo workspaces it lives in the infra repo or a dedicated workspace repo, and declares the list of member repos (URL + branch).
- **Infra registry** (central infra repo): one attrset mapping workspace name → static IP, hostname, resource limits, allowed egress hosts, and secret bindings. From this single source Nix renders the proxy policy file, dnsmasq zone, nftables rules, and a per-workspace module each flake imports to learn its own identity.

Adding a workspace = one registry entry + one flake import.

## How the Finished Project Works

### VM lifecycle

- `vm update <name>` — builds the microvm runner from the project flake **on the host** (so outputs land in the shared store and deduplicate across projects) and atomically registers it under `/nix/var/nix/gcroots/per-project/<name>`.
- `vm up <name>` — starts the last-built runner through a fixed, host-declared per-workspace systemd unit with `MemoryMax`/`CPUQuota` from the registry. Runner code executes as the dedicated workspace account, never as root.
- `vm run <name> -- <cmd>` — ephemeral mode: boots with tmpfs-only root, waits for SSH (pinned host key from the registry), runs the command via `direnv exec /project -- <cmd>` so ephemeral and interactive modes see identical environments, propagates the exit code, tears down.
- `vm down <name>` — asks the matching runner to send an ACPI power-button event, then lets the fixed systemd unit terminate the VMM after a timeout as the hammer.
- `vm ls`, `vm status`, `vm ip`, `vm shell`, `vm update` (explicit rebuild), `vm gc` (remove GC roots for retired projects).
- `vm up` boots the **last-built** runner; rebuilding is deliberate via `vm update`. Starts stay instant and GC roots stay meaningful.
- On macOS, the launcher transparently starts the outer Lima VM if needed and proxies commands into it.

Starting and stopping host system units requires authorization, but project code must not run as root. On NixOS, an explicit Seter operator group receives passwordless sudo permission only for exact hidden start/stop commands generated for registered workspaces. The privileged half reloads the host-owned registry and constructs the fixed systemd unit name; it does not accept arbitrary units or commands. Read-only status and SSH shell operations remain unprivileged.

### Filesystem

- **Root:** ephemeral tmpfs. Every boot is clean; VM state cannot rot.
- **`/nix/store`:** the host store, read-only via virtiofs. Anything present on the host is free in every guest. Guests never build into a private store as normal practice — the launcher pre-builds devShells host-side, and/or guests use the host as remote builder/substituter over the bridge so guest-initiated builds also land in the shared store.
- **`/home` (or `/project`):** one persistent block-device-backed volume per project. Holds the working tree, direnv/nix-direnv cache, language/package caches, and Docker's data-root. This is deliberately a **VM-native disk image**, not a host share: overlayfs and build churn on virtiofs is slow and semantically fragile.
- **No host home mounts, no broad host shares.** Working trees are cloned into the VM from the git remote. File movement between host and guest is deliberate (scp/git), not ambient.
- **GC safety:** the per-project GC roots prevent host garbage collection from removing store paths a running or stopped VM depends on.

### Networking

- Each host runs a bridge (e.g. `10.100.0.0/24`); every project has a **static IP and hostname from the registry**, rendered into host DNS (`<name>.vm`) so "reachable from host" means "reachable by name."
- **Inbound (host → guest):** direct to the VM IP — no per-port forwarding. Services, dev web servers, and Docker-published ports inside a VM are simply addressable.
- **Outbound (guest → world):** default-deny in nftables on the bridge. Allowed: DNS to the host's dnsmasq, and traffic redirected (transparent DNAT of ports 80/443) into mitmproxy. Explicit `HTTP(S)_PROXY` env vars are additionally set in guests as a convenience; **transparent redirection is the enforcement**, so software ignoring proxy variables is still caught.
- **Non-HTTP egress** (ssh to the git remote, databases): explicit per-destination nftables allow rules from the registry. Nothing else passes.

### Tailscale

- **Hosts are tailnet nodes.** Every physical NixOS host — and on macOS, the outer Lima VM — runs tailscaled and is a first-class node. This is also how macOS reaches its own inner VMs in the simplest configuration.
- **Exposing guest services to the tailnet** goes via the host, with two tiers:
  - `tailscale serve` proxying to `vm-ip:port` — named, TLS-terminated, per-service, and the tighter default.
  - Advertising the VM bridge subnet as a subnet route — zero per-service configuration, direct addressing of all VMs, gated only by tailnet ACLs. Use deliberately: it exposes the whole bridge to whatever the ACLs permit.
- **Per-VM tailnet identity** is available when a workspace genuinely needs it: run tailscaled inside that guest with an ephemeral, tagged node key, and scope its access with tag-based ACLs. Ephemeral keys mean discarded VMs clean up after themselves.
- **Remote builds ride the tailnet:** the macOS outer VM uses the NixOS machines as remote builders over Tailscale, and a tailnet-reachable binary cache can substitute builds for all hosts.

### Proxy and secrets

- One mitmproxy instance per host, as a NixOS systemd service, with a Python addon whose entire configuration is a Nix-rendered `policy.json` (project IPs, allowlists, secret bindings) merged with real secret values from agenix/sops-nix at activation — **secrets never enter the Nix store or the guests**.
- Guests receive placeholder values (`TOKEN=placeholder-…`); the addon rewrites them to real credentials only when the destination host matches that secret's binding. A leaked placeholder is worthless.
- Denials return a synthesized 403 with a human-readable reason — failures in guests are self-explanatory, not mysterious timeouts.
- **SNI passthrough** (no decryption, still allowlisted) for cert-pinned tooling and bulk endpoints such as container registries and `cache.nixos.org`, keeping the Python proxy off the high-throughput path.
- Every request is logged with project, method, host, and path.
- The proxy CA certificate is generated once per site, kept host-side, and baked into guest images declaratively (`security.pki.certificates`); tools with private trust stores are fixed case by case or routed via passthrough.
- The `policy.json` schema is the **stable contract**: the enforcement engine (mitmproxy today) can be replaced later without touching flakes, images, or nftables.

### Devices

- No USB passthrough. Host-side daemons are forwarded as sockets: the adb server runs on the physical host (where the USB is) and guests use `ADB_SERVER_SOCKET=tcp:<host>:5037`. The pattern generalizes to any device with a host daemon, and works identically through the macOS nesting layers.

### direnv

- **Inside the guest:** standard `use flake`. Persistent `/home` keeps allow-state and the nix-direnv cache; activation is instant because the devShell was pre-built into the shared store.
- **On the host:** the same `.envrc` detects the side of the boundary (marker file `/etc/vm-guest` baked into images) and, on the host, exports control-plane variables instead: `VM_IP`, `DOCKER_HOST=ssh://dev@<vm-ip>` (host Docker CLI drives the daemon **inside** the VM), service URLs. It prints VM status but **never** starts VMs as a side effect of `cd`.

### Multi-repo workspaces

For split or dependent repositories that are developed together, one workspace VM hosts several repos:

- **Layout:** `/project/{repo-a,repo-b,repo-c}`, each cloned from the git remote into the persistent volume. The workspace flake declares the member repos; `vm init` (or first boot) clones any that are missing, after which git owns the working trees.
- **Per-repo direnv still applies:** each repo keeps its own `.envrc`/`use flake` exactly as if standalone. Repos don't need to know they're co-tenants, and the same repo can be a member of other workspaces without modification. The launcher pre-builds all member devShells and registers a GC root per repo under the workspace's name.
- **Dependent development is the point:** path-based references between repos (local package links, flake inputs overridden to `path:../repo-b`), and compose setups spanning services from several repos, work naturally because the trees share one filesystem — the thing separate VMs would make painful.
- **Shared fate is the trade:** co-tenant repos share the VM's blast radius — a compromised dependency in one can touch the others' trees and use the workspace's credentials. That is acceptable precisely when repos are genuinely coupled (they share fate at integration time anyway). Keep workspaces cohesive: repos that merely happen to share an owner do not belong in one VM for convenience.
- **Registry impact:** still one entry — the workspace's egress allowlist and secret bindings are the union of what its member repos need.

### What the system deliberately does not do

- No ambient sharing of the host home directory, host credentials, or host dotfiles into guests.
- No real secrets in guest filesystems, env vars, or images — placeholders only.
- No user-mode/slirp networking and no per-port forward configuration — routable per-VM IPs instead.
- No writable store share, no guest-local private stores as standard practice.
- No auto-start of VMs from shell hooks; lifecycle is explicit.
- No always-on project VMs; the fleet's idle cost is near zero (the outer macOS VM being the accepted exception).
- No in-guest hardening layers (gVisor, AppArmor profiles, etc.) — the VM boundary is the security boundary; further layers add friction without addressing a realistic residual threat.
- No pretense of containing a motivated attacker holding a VM-escape zero-day: the design targets malicious dependencies, hostile repos, and misbehaving agents. Host kernel and VMM stay updated; known-hostile samples still don't get run intentionally.

## Known Limitations

- **macOS requires M3+ and macOS 15+** for nested virtualization; older Apple Silicon has no viable path in this design.
- Nested virtualization taxes I/O-heavy workloads (container builds) more than CPU-bound ones; the outer VM also holds a standing resource reservation.
- TLS interception produces a recurring trickle of per-tool trust-store fixes; passthrough is the escape hatch.
- The placeholder mechanism covers HTTP(S) only; non-HTTP credentials need other handling (see below).
- mitmproxy is a userspace Python proxy — adequate for API/package traffic, not for sustained bulk transfers (mitigated by passthrough).
- Subnet-routing the bridge to the tailnet exposes all VMs to whatever the ACLs permit; `tailscale serve` per service is the tighter alternative.
- Snapshot/resume of running VMs is not a goal; fast clean boots plus persistent volumes replace it.

## Future Improvements

- **Per-project SSH deploy keys.** Replace agent forwarding with per-project keys scoped in the git server to that project's repositories, so a compromised VM can at most damage its own project's history.
- **Infra-repo protection.** The registry is the root of trust: require signed commits, never run agents against the infra repo from inside an environment it configures, and have the proxy log a policy diff summary whenever `policy.json` changes so silent widening is visible.
- **Guest-output hygiene.** Sanitize terminal escape sequences where guest output crosses to the host; keep deliberate conventions for clipboard and file movement.
- **Tighter egress tiers for agent workloads.** Agent-heavy projects get a stricter registry tier (package registries and the LLM API endpoint only), since agents are the workload most likely to attempt unexpected destinations.
- **Persistent-volume snapshots.** Nightly host-side btrfs/zfs snapshots or restic backups of the per-project volumes — outside the guests' reach — so even "the agent trashed its own /home" is a rollback.
- **Engine swap behind the policy contract.** If profiling ever shows the proxy hot on a critical path beyond what passthrough fixes, reimplement the same `policy.json` semantics on a faster engine (Go/Envoy) without touching the rest of the system.
