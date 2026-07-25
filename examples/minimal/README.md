# Minimal guest

This example is the smallest reference consumer of Seter's guest module. It demonstrates:

- a Cloud Hypervisor runner;
- an ephemeral tmpfs root;
- a read-only virtiofs share of the host Nix store;
- a persistent ext4 volume mounted at `/project`;
- an optional static tap interface; and
- an SSH service for the unprivileged `seter` user.

Build the runner from the repository root:

```console
nix build .#nixosConfigurations.minimal.config.microvm.declaredRunner
```

Run the hardware-assisted boot verification on an x86_64 Linux host with KVM:

```console
nix run .#test-minimal
```

The verification boots a dedicated test variant twice and checks the boundary marker, tmpfs root, writable project volume, read-only Nix store, active SSH service, and persistent SSH host identity. It runs outside the Nix build sandbox because it requires `/dev/kvm` and host-side virtiofs.

Cloud Hypervisor requires a separately running `virtiofsd` for command-line runners. Seter's host module manages it and the tap interface for registered workspaces. For manual experimentation outside that module, use the runner's `virtiofsd-run` helper before `microvm-run` and create/configure the `seter-minimal` tap interface.

The example deliberately contains no authorized key, proxy CA, secrets, personal addresses, or host-specific paths. Override `seter.guest.ssh.authorizedKeys` and networking values in a real workspace definition. After the host proxy first starts, export its public CA with `seter proxy-ca`, review and commit the certificate in trusted configuration, and set `seter.guest.proxyCaCertificate = builtins.readFile ./seter-proxy-ca-cert.pem`.
