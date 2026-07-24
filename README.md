# Seter

Seter runs development projects in isolated, Nix-managed micro-VMs. It is currently an early scaffold; lifecycle and enforcement behavior are not implemented yet.

See [project-description.md](./project-description.md) for the intended architecture and threat model.

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

The current modules and CLI establish public interfaces only. They deliberately do not claim to enforce isolation, networking policy, or secret handling yet.
