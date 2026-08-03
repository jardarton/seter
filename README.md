# Seter

<p align="center">
  <img src="assets/seter-logo.png" alt="Seter logo: a Norwegian summer farm with subtle circuit-board elements" width="280">
</p>

Seter runs each development project in its own micro-VM, with only the authority you declared for it.

## The problem

Your development environment has far more authority than your code needs.

A test runner can read your SSH keys. A `postinstall` script in a transitive dependency can reach any host on the internet, and any machine on your LAN. A coding agent you asked to fix one bug can push to every repository your token unlocks. Each of these is one process on your machine, running with your user's full authority.

Container-based development environments do not change this. They isolate *dependencies*, not *authority*. The kernel is shared, egress is unrestricted, and your credentials usually sit in the container's environment.

The [threat cases](./docs/threat-cases/) in this repository record real incidents of this kind. They are source-based summaries kept for analysis and testing. Including one does not mean that Seter has been verified against it, or that Seter protects against it today.

## What Seter does

Seter gives every project a **workspace**: a micro-VM that holds one repository and nothing else it was not granted.

- **A real isolation boundary.** Each workspace is a KVM micro-VM with its own kernel, not a container.
- **The network is closed until you open it.** A workspace reaches only the destinations you list. DNS, HTTP, HTTPS, and direct TCP each have their own policy. Everything else is refused, including the host and the LAN.
- **Credentials never enter the workspace.** The guest holds a public placeholder. The host proxy exchanges it for the real token, and only for the exact host and path you bound it to.
- **Policy is your NixOS configuration.** Workspaces are declared, reviewed, and deployed like any other part of your system. There is no mutable state to drift.
- **Ordinary projects work unchanged.** A repository needs only its normal development flake. It needs no knowledge of Seter and no NixOS guest configuration.

## Status

Seter is early software, and it is usable today on NixOS with KVM.

Working now: trusted host deployment, per-workspace micro-VMs, safe and retryable repository bootstrap over authenticated HTTPS, the complete network boundary, destination-bound secret injection, strict SSH host-key checking, persistent storage, and the daily `init` / `shell` / `run` / `down` cycle. An ordinary development flake runs inside a workspace.

Not there yet: macOS support ([roadmap](./macos-roadmap.md)), guest profiles other than `default`, IPv6, and automated repository credentials. Option names and the registry schema can still change between versions.

Start with the [quickstart](./quickstart.md) to configure a host and launch your first workspace. See [project-description.md](./project-description.md) for the intended architecture and threat model.

## How Seter compares

Most of these tools solve a different problem, and solve it well. The columns below are the four properties Seter is built for, so the table shows where Seter differs — not which tool is better.

| Tool / normal mode | Isolation boundary | Built-in egress control per workspace | Declarative environment or policy | Credential kept outside the workload |
|---|---|---|---|---|
| `nix develop` | none — dependencies only | none | yes, Nix | no |
| devenv shell | none; optional OCI container mode shares its runtime's kernel | none | yes, Nix | no |
| bubblewrap | same kernel | network namespace on or off; finer policy requires external setup | command-line construction | no |
| Firejail | same kernel | network namespaces and custom IPv4/IPv6 firewall rules | yes, security profiles | no |
| Docker, devcontainers | same kernel | unrestricted by default; none/internal networks, but no destination-aware policy | yes, Dockerfile, Compose, or `devcontainer.json` | no |
| Codespaces | dedicated VM containing a dev container | depends on organization networking | yes, `devcontainer.json` | no — repository token is in the environment |
| Ona (formerly Gitpod) | VM | depends on runner/VPC policy | yes, Dev Container and project configuration | no — secrets are injected into the environment |
| Coder | template-defined VM or Kubernetes pod | depends on deployment and template | yes, Terraform templates | no by default |
| microvm.nix | VM | network interfaces, but no policy layer | yes, Nix | no |
| Qubes OS | VM per qube | per-qube firewall | optionally through Salt | yes for selected split services, such as Split GPG |
| **Seter** | **VM** | **default-deny with hostname grants** | **yes, Nix** | **yes, for configured destination-bound HTTP credentials** |

The table describes each tool's normal execution mode and built-in supported mechanisms, not every customization that can be built around it. “Declarative” means that the environment or policy has a supported configuration-as-code representation. The credential column asks whether a supported mechanism can use a runtime credential without making its private value available inside the workload.

Seter is built **on** microvm.nix. It adds the policy layer, the lifecycle, and the credential boundary that a VM alone does not give you.

Seter is not a replacement for Qubes OS. Qubes isolates your whole computing life, across every application you run. Seter isolates one development project, and makes that isolation a reviewable part of your system configuration.

## Core concepts

The trusted NixOS configuration owns one typed **Workspace Registry**. For every entry, the host module builds a trusted `default`-profile **Runner**, includes it in the same NixOS generation, roots its closure, and writes the lifecycle registry consumed by `seter`.

```text
trusted Workspace Registry ── NixOS deployment ──> host policy + Runner
                                                        │
                                                   seter up
                                                        │
                                                   running VM
```

A Runner contains Seter's guest baseline and registered non-secret identity, never project code. The approved HTTPS repository enters later through Workspace Bootstrap. Cold starts validate and execute the already deployed immutable Runner without evaluating Nix. Guest Profile or identity changes therefore use the operator's normal trusted host deployment; there is no `seter update` command.

The trusted [`default` Guest Profile](./docs/guest-profile-default.md) includes
flake-enabled Nix with the private writable store, Git and system HTTPS trust,
OpenSSH lifecycle tooling, direnv/nix-direnv with Bash integration, and a small
interactive shell baseline. A repository needs only its ordinary development
flake; it does not provide Seter or NixOS guest configuration.

The daily lifecycle starts workspaces on demand and stops them only when asked:

```console
seter init project
seter shell project
seter run project -- cargo test
seter status project
seter down project
```

Both `shell` and `run` enter the registered checkout and leave the VM running.
They never approve repository code: review `.envrc` and run `direnv allow`
explicitly in a workspace shell before `run` can load the environment.

## Workspace Registry

Create the workspace directly in trusted NixOS configuration:

```nix
{
  imports = [ seter.nixosModules.host ];

  seter.host = {
    enable = true;
    workspaces.project = {
      repository = {
        url = "https://git.example/owner/project.git";
        # branch = "main";       # null uses the remote default
        # checkoutName = "project";
      };
      guestProfile = "default";
      network = {
        address = "10.100.0.10";
        mac = "02:00:00:00:00:10";
        tap = "seter-project";
      };
      resources = {
        memoryMiB = 4096;
        cpuQuotaPercent = 200;
      };
      ssh.authorizedKeys = [ "ssh-ed25519 AAAA…" ];
      egress.httpHosts = [ "api.example.com" ];
    };
  };

  users.users.alice.extraGroups = [ "seter-operators" ];
}
```

The schema also owns optional repository credential binding, storage image names and capacities, host services, direct-TCP grants, HTTP policy, and destination-bound secrets. Repository URLs must use HTTPS; only the trusted `default` Guest Profile is currently accepted. Evaluation rejects invalid or duplicate network identity, reused volume names, undefined credential bindings, and host/Runner drift.

## Workspace Bootstrap

`seter init <workspace>` starts the host-deployed Runner, leaves it running,
and clones the one approved HTTPS repository into
`/project/<checkout-name>`. A configured branch is selected explicitly;
otherwise Git uses the remote default branch. Bootstrap never evaluates or
approves `.envrc`.

Initialization is retryable. An existing complete checkout succeeds only when
its `origin` exactly matches the registry. An empty directory or partial Git
clone with the approved origin and no working data can be recovered. Seter
rejects symlinks, unrelated content, mismatched remotes, and partial clones
containing working data rather than cleaning, resetting, deleting, or
overwriting them.

For a private repository, bind a dedicated HTTP Authorization value:

```nix
seter.host.workspaces.project = {
  repository = {
    url = "https://git.example/owner/project.git";
    credential = "repositoryToken";
  };
  secrets.repositoryToken = {
    placeholder = "seter-placeholder-repository-0123456789abcdef";
    sourceFile = "/run/secrets/project-repository-token";
    hosts = [ "git.example" ];
    headers = [ "authorization" ];
  };
};
```

The guest stores only the non-secret placeholder in repository-local Git
configuration. The host proxy substitutes the runtime credential only for HTTPS
requests to the exact repository host and path (including its Git smart-HTTP
endpoints), and redacts exact reflections. Requests to sibling repository
paths, traversal-like subpaths, or arbitrary endpoints below the repository
path cannot use the binding. SSH Git is not supported.

The credential source contains the complete Authorization field value, such
as `Bearer <token>` or `Basic <base64-user-and-token>`, so the binding works
with the authentication scheme required by the selected Git service.

The deployed Runner is available at `/etc/seter/runners/<workspace>` and is an explicit dependency of the NixOS system closure. Older NixOS generations retain their corresponding Runners for rollback. The generated registry and systemd units reference that same immutable path, so host activation publishes policy, units, and Runner together rather than maintaining a mutable per-workspace current link. See [Runner deployment](./docs/runner-deployment.md) and [Generated workspace identity](./docs/workspace-identity.md).

## Host runtime plumbing

When `seter.host.enable` is set, the host creates the configured bridge at boot and assigns `seter.host.gateway` to it (`10.100.0.1` by default). Workspace TAP interfaces and the Workspace SSH Identity service remain off while idle. Starting `seter-runtime-<workspace>.target` creates the registered TAP, attaches it to the bridge, stages the root-owned host-created SSH identity for the unprivileged workspace runtime account, and supplies it over a dedicated read-only VirtioFS mount:

```console
sudo systemctl start seter-runtime-project.target
sudo systemctl stop seter-runtime-project.target
```

Each workspace receives a separate host system account and private state directory under `/var/lib/seter/workspaces`. The runtime units never execute helpers from a workspace runner as root.

Inside the guest, the Runner's closure-filtered, read-only EROFS [Store View](./docs/store-visibility.md) is the lower layer of an overlay mounted at `/nix/store`; the host store itself is never exported. A dedicated ext4 image, `<workspace>-nix-store.img` by default, retains the private upper layer and `/nix/var/nix`. Consequently `nix build`, `nix develop`, and nix-direnv can realize missing paths without writing to the host store, while unrelated host-store paths are not enumerable. Guest store GC is disabled because it could create persistent whiteouts over required lower paths; reclaiming space currently means replacing the bounded private image. See [Private writable Nix stores](./docs/nix-store.md).

These units provide VM plumbing only. They do not start the VM. Separate host-owned DNS, proxy, direct-TCP resolver, and nftables services keep every workspace fail-closed while enabling only declared application egress.

## Network isolation

A workspace reaches only the destinations its registry entry declares; everything else is denied, including the host, other workspaces, and your LAN. Host-owned nftables rules bind each TAP to its registered IPv4 and MAC address and reject forged identities. A per-workspace DNS resolver answers only names derived from that workspace's own grants. A transparent proxy intercepts ports 80 and 443, requires the TLS SNI and the HTTP host to agree, and pins the reviewed name to a public IPv4 address, so an allowed name cannot rebind onto a private service. Non-HTTP destinations need an explicit `allowedTCP` grant, and every other protocol — including IPv6, QUIC, and ICMP — stays blocked.

**Seter requires and enables NixOS's native `networking.nftables` backend. This switches the host firewall backend from legacy iptables and may require changes for Docker, libvirt, or other software that manages iptables rules. Review those services before enabling the host module.**

Reference documentation:

- [The workspace network boundary](./docs/network-boundary.md) — the complete policy: layer-2 rules, DNS, interception, TLS passthrough, direct TCP, host service relays, auditing, and proxy CA trust.
- [DNS policy](./docs/dns-policy.md) — wire-level rules and resource limits.
- [Destination-bound secret injection](./docs/secret-injection.md) — how a workspace uses a credential it never receives.

## VM lifecycle

The host declares an on-demand `seter-vm-<workspace>.service`. The CLI controls that fixed unit rather than executing a VMM itself. Starting it brings up `seter-runtime-<workspace>.target` and launches `microvm-run` from the Runner embedded in the active NixOS generation. Stopping it uses the matching immutable Runner's shutdown helper, with a systemd timeout and forced termination as a fallback, then removes the TAP and identity socket. Project, Home, and private Nix-store volumes are retained.

`seter status [workspace]` reports `not-deployed`, `stopped`, `starting`, `running`, `stopping`, or `failed`. A stopped single-workspace status exits with code 3 for scripting.

Lifecycle control is privileged through systemd. Members of `seter.host.operatorGroup` (`seter-operators` by default) may use `seter up` and `seter down` without a sudo password. The CLI elevates only an exact hidden start or stop operation for the named, registered workspace; generated sudoers rules do not grant arbitrary `seter`, `systemctl`, or root command execution. The privileged operation discards environment overrides, reloads the root-owned registry, and constructs the fixed unit name itself.

Runner deployment is not a CLI privilege: it occurs only through trusted NixOS deployment. Runner code executes as the workspace account, never as host root. See [Lifecycle authorization](./docs/lifecycle-authorization.md) for the trust boundary and implementation rules.

## Workspace SSH Identity

SSH never silently trusts a network-provided key. Trusted host activation creates a root-owned identity before the first boot and publishes only its public half to members of the operator group:

```console
seter ssh-host-key project
```

`seter shell project` and `seter run project -- <command>` read that
host-created public key and use strict host-key checking automatically, with no
SSH agent or X11 forwarding. Both start the workspace when needed, enter its
registered checkout, and leave it running. `run` executes through `direnv`, so
an unreviewed `.envrc` fails closed until the operator explicitly runs
`direnv allow` in `seter shell`. Configure the developer's public login key in
the registry at `ssh.authorizedKeys`.

## Development

```console
nix develop
cargo test
cargo run -- --help
nix flake check
```

The default development shell is available on `x86_64-linux`, `aarch64-linux`, and Apple Silicon macOS (`aarch64-darwin`).

On `x86_64-linux`, `nix flake check` includes a nested-KVM lifecycle test that boots the host-deployed default Runner through the CLI, connects over SSH, and verifies project-volume persistence across a restart. It requires writable `/dev/kvm` and nested virtualization support.

## Flake outputs

- `devShells.{x86_64-linux,aarch64-linux,aarch64-darwin}.default`: Rust development shell
- `packages.<system>.seter`: Rust CLI
- `apps.<system>.default`: Seter CLI application
- `nixosModules.host`: host-side Seter module
- `nixosModules.guest`: low-level guest building block used by Seter's trusted profile and standalone verification
- `nixosConfigurations.minimal`: buildable reference microVM
- `apps.x86_64-linux.test-minimal`: KVM-backed minimal guest verification
