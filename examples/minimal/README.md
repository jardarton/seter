# Minimal guest

This example is a standalone boot verification for Seter's low-level guest module. The normal product path does not ask repositories to export a NixOS guest: `seter.nixosModules.host` builds a trusted `default`-profile Runner directly from each `seter.host.workspaces` registry entry.

The standalone example remains useful for testing:

- a Cloud Hypervisor Runner;
- tmpfs root and persistent Project/private-Nix volumes;
- the read-only VirtioFS lower store and writable overlay;
- guest networking and SSH plumbing.

Run it with:

```console
nix run .#test-minimal
```

Cloud Hypervisor requires a separately running `virtiofsd` for command-line Runners. The test application supplies that daemon. Real workspaces use host-owned `seter-runtime-<workspace>.target` plumbing.

The example deliberately contains no real authorized key, credential, repository, personal address, or host-specific path.
