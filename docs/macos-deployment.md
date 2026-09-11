# macOS bootstrap and deployment

## Scope

This manual deployment path has been exercised on an M5 Mac. See the
[validation summary](./macos-validation.md) for coverage and remaining limits,
and the [operator workflow](./macos-workflow.md) for daily use after deployment.

This procedure creates one persistent `aarch64-linux` Seter Host from the
checked-in [`lima/seter.yaml`](../lima/seter.yaml) template and remotely deploys
a consumer-owned NixOS flake. Seter commands still run in the Linux Seter Host.
There is no Darwin Seter executable.

The bootstrap image is
`nixos-lima-v0.2.1-aarch64.qcow2`, selected by an immutable release URL and
verified by Lima against the checked-in SHA-512 digest. Updating either value is
a reviewed dependency update, not an automatic move to a newer image.

## Trust and persistence

The Seter Host is trusted. Lima's root disk contains `/nix`, `/var/lib/seter`,
the Workspace SSH Identities, and all Workspace volume images. The only macOS
mount is the explicitly selected Client Exchange Directory at
`/workspace/seter-exchange`; it is read-write and must never be mounted into a
Workspace.

`limactl stop`, `limactl start`, macOS reboot, and NixOS redeployment retain the
root disk. **`limactl delete seter` destroys the Seter Host and every Workspace
volume. Do not use it.** This milestone provides no recovery from instance
deletion or disk corruption and no backup/restore facility.

## Prerequisites

Nested virtualization requires Apple Silicon M3 or newer and macOS 15 or newer;
physical validation so far covers an M5 Mac, not every eligible combination.
Install Nix with flakes enabled and Lima 2.0 or newer. The wrapper currently
recognizes M3, M4, and M5 chips and rejects other CPU/OS combinations.

Prepare one dedicated exchange directory:

```sh
mkdir -p "$HOME/seter-exchange"
cp -R examples/macos-consumer "$HOME/seter-exchange/consumer"
```

After creating the instance below, follow the example's README: obtain the
operator name from the guest rather than assuming the macOS result of `id -un`
is a valid Linux account name. Replace the deliberately unusable public key,
configure the Workspace Registry and Policy File, and run `nix flake lock` so
the consumer deployment is reproducible at Seter's tested nixpkgs revision.
Keep these site-specific files in the consumer directory, not this repository.

## Create the bootstrap Seter Host

From a Seter checkout, validate without changing Lima:

```sh
nix run path:.#macos-host -- check
```

Create the instance. The defaults are 8 CPUs, 16 GiB RAM, and a 120 GiB
persistent disk:

```sh
nix run path:.#macos-host -- create "$HOME/seter-exchange"
```

Override sizing only at creation time, for example:

```sh
SETER_LIMA_CPUS=10 \
SETER_LIMA_MEMORY=24 \
SETER_LIMA_DISK=200 \
  nix run path:.#macos-host -- create "$HOME/seter-exchange"
```

The wrapper refuses to replace an existing `seter` instance and requires the
exchange directory to exist. Set `SETER_LIMA_INSTANCE` consistently if a
non-default instance name is needed.

## Deploy from macOS and build on Linux

Deploy the example configuration:

```sh
nix run path:.#macos-host -- \
  deploy "$HOME/seter-exchange/consumer" seter-host
```

The wrapper obtains Lima's generated SSH configuration, evaluates the flake in
the macOS Nix process, and invokes `nixos-rebuild` with the Seter Host as both
`--build-host` and `--target-host`. Consequently all `aarch64-linux` closures
are built or substituted in the Seter Host; another Linux machine and Darwin
to Linux cross-compilation are not required.

The first deployment installs Linux 6.12 LTS for the next boot. Stop and start
the retained instance once after that deployment, then verify `uname -r`
reports `6.12.*` before starting a Workspace. This restart retains the disk.
The module projects Lima's generated bootstrap key directly from immutable
cidata into a root-controlled runtime key file during activation and cold boot.
Later deployments therefore accept both that key and the consumer operator
key, so activation does not strand the deploy wrapper.

The reusable `seter.nixosModules.limaHost` module provides:

- nixos-lima guest-agent and bootstrap-user compatibility;
- remote SSH/Nix deployment prerequisites;
- the accepted Linux 6.12 LTS ARM kernel and QEMU/KVM Runner selection;
- Lima disk boot and filesystem declarations; and
- the ordinary `seter.nixosModules.host` implementation.

It deliberately does not provide users, Registry entries, Policy Grants,
secret sources, resource choices, or `system.stateVersion`.

The first deployment generates the Host proxy CA. Before starting a Workspace,
export and review its public certificate, set `proxyCaCertificate` in the
consumer configuration, and redeploy as described in the
[consumer example](../examples/macos-consumer/README.md). Never copy the CA's
private key into the exchange directory or a Nix store.

## Verify deployment preserves state

Before a later redeployment, stop each running Workspace normally and record
the outer disk identity and Workspace state:

```sh
limactl shell seter -- bash -lc '
  findmnt -no UUID /
  sudo find /var/lib/seter/workspaces -maxdepth 2 -type f \
    -printf "%p %s bytes\n" | sort
'
```

Stop each Workspace with `seter down`. For QEMU Runners, the Host requests an
ACPI powerdown through the private QMP socket and waits for QEMU to exit, so
systemd does not terminate the VMM while the guest flushes its filesystems.
The physical-Mac acceptance run verified unsynchronized Project, Home, and
private Store markers byte-for-byte after this lifecycle. Do not use important
data as an acceptance marker.

Deploy the next generation, then run the same command. The root filesystem UUID
and existing volume paths/sizes must be unchanged. Start the Workspace and
verify Project, Home, and private Nix-store marker files rather than relying
only on image sizes. NixOS activation changes the system generation in place;
the module contains no disk formatter or image replacement operation.

Record the same check when changing the QEMU, guest storage, or shutdown path.
Keep disk identifiers and raw command output private; publish only whether the
identity and marker comparisons passed.

## Interrupted deployment recovery

An interrupted evaluation or build does not activate a generation. Correct the
cause and rerun the same `deploy` command; Nix resumes from valid store paths.

If activation was interrupted but SSH still works:

1. inspect `systemctl --failed` and `sudo nixos-rebuild list-generations`;
2. rerun the same deployment;
3. if the new generation is faulty, run `sudo nixos-rebuild switch --rollback`
   in the Seter Host and then correct the consumer flake;
4. verify the root UUID and Workspace marker files before restarting a
   Workspace.

If the Seter Host stopped, use:

```sh
nix run path:.#macos-host -- start
nix run path:.#macos-host -- deploy "$HOME/seter-exchange/consumer" seter-host
```

Do not create a replacement instance over the problem, detach or rewrite the
Lima disk, run `limactl delete`, or promise recovery from a corrupt disk. Those
cases are outside this milestone.
