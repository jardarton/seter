# Seter

<p align="center">
  <img src="assets/seter-logo.png" alt="Seter logo: a Norwegian summer farm with subtle circuit-board elements" width="280">
</p>

Seter runs development projects in isolated, Nix-managed micro-VMs. Guest and host lifecycle behavior, a fail-closed workspace network boundary, and restricted guest DNS are implemented as an early vertical slice; permitted application egress, proxying, and secret handling are not implemented yet.

See [project-description.md](./project-description.md) for the intended architecture and threat model.

## Core concepts

A project repository imports `seter.nixosModules.guest` in its flake and exports a NixOS microVM configuration. A NixOS host imports `seter.nixosModules.host` and registers that project as a workspace.

```text
project flake                     NixOS host
     │                                │
     └─ VM installable ── seter update ──> last-built runner
                                               │
                                          seter up
                                               │
                                          running VM
```

- **Workspace:** one isolated development environment, usually associated with one project repository.
- **Installable:** the Nix reference identifying what to build, for example `github:owner/project#nixosConfigurations.guest.config.microvm.declaredRunner`.
- **Runner:** the immutable build result containing the launcher and references needed to boot that specific VM configuration.

`seter update <workspace>` builds the installable and retains its runner. `seter up <workspace>` starts that last-built runner without rebuilding, so configuration changes only take effect after an explicit update.

The lifecycle is explicit:

```console
seter update project        # builds unprivileged, then prompts for the install step
seter up project
seter status project
seter shell project
seter down project
```

`update` atomically installs the immutable runner under the workspace state directory and registers a GC root under `/nix/var/nix/gcroots/per-project`. `up` never evaluates Nix. The VM runs as its dedicated `seter-*` system account with the registry's memory and CPU limits; runner-provided TAP and VirtioFS helpers are not executed.

## Host workspace registry

Host workspace entries are typed and validated by `nixosModules.host`:

```nix
seter.host = {
  enable = true;
  workspaces.project = seter.lib.mkWorkspace {
    runnerInstallable =
      "github:owner/project#nixosConfigurations.guest.config.microvm.declaredRunner";
    ip = "10.100.0.10";
    mac = "02:00:00:00:00:10";
    tap = "seter-project";
  };
};

# Starting and stopping registered workspaces is an explicit host capability.
users.users.alice.extraGroups = [ "seter-operators" ];
```

Every workspace on one host bridge must have a unique IPv4 address, MAC address, tap interface, and hostname. Evaluation fails when entries conflict. If the guest overrides `seter.guest.projectVolume.image`, pass the same basename as `projectImage` to `mkWorkspace` so offline host-key enrollment reads the correct volume. The host module writes a versioned, lifecycle-only projection to `/etc/seter/workspaces.json`; lifecycle commands read this registry.

## Host runtime plumbing

When `seter.host.enable` is set, the host creates the configured bridge at boot and assigns `seter.host.gateway` to it (`10.100.0.1` by default). Workspace TAP interfaces and VirtioFS daemons remain off while idle. Starting `seter-runtime-<workspace>.target` creates the registered TAP, attaches it to the bridge, and starts a host-owned `virtiofsd` that exposes only `/nix/store` read-only:

```console
sudo systemctl start seter-runtime-project.target
sudo systemctl stop seter-runtime-project.target
```

The VirtioFS socket is `/run/seter/<workspace>/virtiofs-ro-store.sock`. Each workspace receives a separate host system account and private state directory under `/var/lib/seter/workspaces`. The runtime units never execute helpers from a workspace runner as root.

These units provide VM plumbing only. They do not start the VM or enable forwarding, NAT, or permitted application egress. Separate host-owned DNS and nftables services keep every workspace fail-closed.

## Network isolation

Every workspace TAP is an isolated bridge port. Host-owned nftables rules bind each TAP to its registered IPv4 and MAC addresses, reject forged ARP and IPv4 identities, block IPv6 until it has an explicit policy, and deny workspace-initiated traffic to the host, other workspaces, and routed networks. Host-initiated connections such as `seter shell` remain available.

Seter requires and enables NixOS's native `networking.nftables` backend so its tables participate in the host's complete atomic firewall transaction. **This switches the host firewall backend from legacy iptables and may require changes for Docker, libvirt, or other software that manages iptables rules. Review those services before enabling the host module.**

The nftables policy is installed before any TAP can start. A policy-loading failure prevents the workspace runtime from starting, and stopping nftables stops active workspace TAPs before removing their rules. The boundary does not rely on forwarding being disabled or on unrelated firewall rules rejecting traffic.

A separate unprivileged dnsmasq instance runs on demand for each active workspace behind the bridge gateway. Workspaces may query the gateway over TCP or UDP, but only names derived from that workspace's configured HTTP, passthrough, and direct-TCP egress destinations are forwarded. nftables redirects each registered source address to its own resolver, so one workspace's destinations do not broaden another's DNS policy. dnsmasq forwarding accepts the configured name and its subdomains; this suffix behavior is an accepted initial limitation, while later connection enforcement will still use the configured destination policy. AAAA answers are filtered until Seter has an IPv6 policy. Direct DNS to outside resolvers remains blocked.

By default DNS queries are logged to each workspace's `seter-dns-<workspace>.service` journal. This provides useful early policy visibility but can be noisy and can reveal project access patterns; set `seter.host.dns.logQueries = false` to disable it. Query logging is an initial audit mechanism and may be replaced with more selective logging later. Set `seter.host.dns.upstreamServers` to explicit IPv4 resolver addresses, or leave it empty to use the host's existing `/etc/resolv.conf` resolvers. Host applications resolve registered workspace hostnames through generated `/etc/hosts` entries; Seter does not replace the host resolver.

There is intentionally no permitted application egress yet. Direct TCP allowances, HTTP proxying, and secret injection remain future milestones.

## VM lifecycle

The host also declares an on-demand `seter-vm-<workspace>.service`. The CLI controls that fixed unit rather than executing a VMM itself. Starting it brings up `seter-runtime-<workspace>.target`, snapshots the installed runner as `booted`, and launches `microvm-run` from the workspace's private state directory. Stopping it uses the matching `booted/bin/microvm-shutdown`, with a systemd timeout and forced termination as a fallback, then removes the TAP and VirtioFS socket. The project volume is retained.

`seter status [workspace]` reports `not-built`, `stopped`, `starting`, `running`, `stopping`, or `failed`. A stopped single-workspace status exits with code 3 for scripting.

Lifecycle control is privileged through systemd. Members of `seter.host.operatorGroup` (`seter-operators` by default) may use `seter up` and `seter down` without a sudo password. The CLI elevates only an exact hidden start or stop operation for the named, registered workspace; generated sudoers rules do not grant arbitrary `seter`, `systemctl`, or root command execution. The privileged operation discards environment overrides, reloads the root-owned registry, and constructs the fixed unit name itself.

`seter update` still performs the potentially untrusted Nix build as the invoking user, then separately elevates its narrowly scoped install operation to update root-owned state and GC roots. Project runner code always executes as the workspace account, never as root. See [Lifecycle authorization](./docs/lifecycle-authorization.md) for the trust boundary and implementation rules.

## SSH host-key enrollment

SSH never silently trusts a network-provided key. After the first boot has generated the guest identity, stop the workspace and read its public key directly from the host-owned ext4 project image:

```console
seter up project
seter down project
seter ssh-host-key project
```

Review the printed fingerprint, copy the public key into the workspace registry's `knownHostKey`, rebuild the host configuration, and then use `seter shell project`. Shell connections use the registered IP and user, strict host-key checking, and no SSH agent or X11 forwarding. The guest flake must separately include the developer's public login key in `seter.guest.ssh.authorizedKeys`.

## Development

```console
nix develop
cargo test
cargo run -- --help
nix flake check
```

On `x86_64-linux`, `nix flake check` includes a nested-KVM lifecycle test that boots the minimal guest through the host module and CLI, connects over SSH, and verifies project-volume persistence across a restart. It requires writable `/dev/kvm` and nested virtualization support.

## Flake outputs

- `packages.<system>.seter`: Rust CLI
- `apps.<system>.default`: Seter CLI application
- `nixosModules.host`: host-side Seter module
- `nixosModules.guest`: project guest module
- `lib.mkWorkspace`: workspace registry constructor
- `nixosConfigurations.minimal`: buildable reference microVM
- `apps.x86_64-linux.test-minimal`: KVM-backed minimal guest verification

## Status

The guest boundary has a tested minimal vertical slice. The host exposes a validated workspace registry, lifecycle-owned bridge/TAP/VirtioFS plumbing, fixed per-workspace VM services, fail-closed TAP identity and network isolation, restricted guest DNS, and CLI operations for runner updates, start, status, shutdown, strict SSH shell access, and offline SSH host-key enrollment. Permitted application egress, proxy enforcement, and secret handling are not implemented yet.
