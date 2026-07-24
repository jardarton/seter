# Seter

Seter runs development projects in isolated, Nix-managed micro-VMs. It is currently an early scaffold; lifecycle and enforcement behavior are not implemented yet.

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
```

Every workspace on one host bridge must have a unique IPv4 address, MAC address, tap interface, and hostname. Evaluation fails when entries conflict. The host module writes a versioned, lifecycle-only projection to `/etc/seter/workspaces.json`; `seter list` and `seter ip <workspace>` read this registry.

## Host runtime plumbing

When `seter.host.enable` is set, the host creates the configured bridge at boot and assigns `seter.host.gateway` to it (`10.100.0.1` by default). Workspace TAP interfaces and VirtioFS daemons remain off while idle. Starting `seter-runtime-<workspace>.target` creates the registered TAP, attaches it to the bridge, and starts a host-owned `virtiofsd` that exposes only `/nix/store` read-only:

```console
sudo systemctl start seter-runtime-project.target
sudo systemctl stop seter-runtime-project.target
```

The VirtioFS socket is `/run/seter/<workspace>/virtiofs-ro-store.sock`. Each workspace receives a separate host system account and private state directory under `/var/lib/seter/workspaces`. The runtime units never execute helpers from a workspace runner as root.

These units provide VM plumbing only. They do not start the VM, configure DNS, enable forwarding or NAT, or enforce the eventual egress policy.

## Development

```console
nix develop
cargo test
cargo run -- --help
nix flake check
```

## Flake outputs

- `packages.<system>.seter`: Rust CLI
- `apps.<system>.default`: Seter CLI application
- `nixosModules.host`: host-side Seter module
- `nixosModules.guest`: project guest module
- `lib.mkWorkspace`: workspace registry constructor
- `nixosConfigurations.minimal`: buildable reference microVM
- `apps.x86_64-linux.test-minimal`: KVM-backed minimal guest verification

## Status

The guest boundary has a tested minimal vertical slice. The host exposes a validated workspace registry consumed by `seter list` and `seter ip`, plus tested bridge, lifecycle-owned TAP, and read-only VirtioFS plumbing. VM lifecycle and host policy enforcement are not implemented yet; the project deliberately does not claim to enforce isolation, egress policy, or secret handling.
