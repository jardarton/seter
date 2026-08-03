# macOS Phase 2 completion procedure

## Purpose and current state

This procedure completes Phase 2 of the
[macOS integration roadmap](../macos-roadmap.md): make the existing Seter CLI,
Host, Guest Profile, and trusted Runner work on `aarch64-linux` without adding
a Darwin CLI or the Phase 3 Lima deployment interface.

The initial Phase 2 implementation is present:

- `seter.host.runner.hypervisor = "qemu"` selects the nested ARM backend;
- the Host and Workspace use Linux 6.12 LTS on `aarch64-linux`;
- QEMU uses KVM-only acceleration and GIC `max`;
- the VM unit loads the host-created Workspace SSH Identity as a private
  systemd credential;
- the Runner delivers that identity through QEMU `fw_cfg`, with no identity
  virtiofs device or shareable memfd/NUMA memory configuration;
- Workspace vCPU count is consumer-owned and included in Registry/Runner
  identity validation; and
- `checks.aarch64-linux.arm-qemu-runner` builds and inspects the generated
  four-vCPU Runner command.

Phase 2 is not accepted until the ARM builds and the ordinary product lifecycle
pass on the physical Mac's LTS Seter Host and the native `x86_64-linux`
regression suite still passes.

## Constraints

Keep these boundaries while completing the work:

- Run Seter commands inside the `aarch64-linux` Seter Host. Do not add an
  `aarch64-darwin` executable.
- Reuse the dedicated Phase 1 Lima instance with Linux 6.12 LTS, or create a
  separate disposable acceptance instance with the same accepted kernel. Do
  not alter or delete retained Phase 1 evidence.
- Do not run a NixOS VM test inside Lima; that would add an unintended third
  virtualization layer. Boot the generated Workspace Runner directly through
  the normal Host systemd units and Seter CLI.
- QEMU is only the selected nested ARM path. Cloud Hypervisor remains the
  native-Linux default.
- Do not permit TCG fallback. The generated command must contain
  `accel=kvm`, not `accel=kvm:tcg`.
- Keep both virtualization layers on Linux 6.12 LTS.
- Use four Workspace vCPUs for physical acceptance, matching the accepted
  Phase 1 practical configuration.
- Do not restore the QEMU identity virtiofs share. The private key must not
  enter the Nix store or QEMU command line as data; only its runtime credential
  path may appear there.
- Preserve the existing strict SSH host verification, filtered Store View,
  separate persistent volumes, dedicated VMM account, cgroup limits, exact TAP
  binding, and host-owned network policy.

## 1. Build the ARM outputs

Run from the repository mounted at `/workspace/seter-exchange` in the LTS Seter
Host. Using `path:.` is important while testing a worktree containing untracked
files.

```sh
limactl shell seter-phase1-lts -- bash -lc '
  set -eu
  cd /workspace/seter-exchange
  nix build \
    path:.#checks.aarch64-linux.seter \
    path:.#checks.aarch64-linux.nixos-host-module \
    path:.#checks.aarch64-linux.nixos-guest-module \
    path:.#checks.aarch64-linux.workspace-registry \
    path:.#checks.aarch64-linux.workspace-uniqueness \
    path:.#checks.aarch64-linux.arm-qemu-runner
'
```

Record the Seter revision and all resulting output paths. The
`arm-qemu-runner` check verifies the generated script contains:

- `qemu-system-aarch64`;
- `-M 'virt,accel=kvm,gic-version=max'`;
- `-smp 4`;
- a Linux 6.12 kernel;
- `fw_cfg` pointing at the private `seter-vm-<name>.service` credential; and
- no `vhost-user-fs` or `memory-backend-memfd` argument.

A build or evaluation failure is Phase 2 work. Do not work around it with
cross-compilation, TCG, a different kernel, or a different VMM.

## 2. Prepare a temporary product-lifecycle configuration

Create a checked-in, test-only NixOS configuration for the dedicated acceptance
instance. It may compose the existing Phase 1 Lima guest configuration, but it
must import `seter.nixosModules.host` and use the ordinary Host module rather
than reproducing its systemd units in a script.

Configure one Workspace with:

```nix
seter.host = {
  enable = true;
  runner.hypervisor = "qemu";

  workspaces.phase2 = {
    repository.url = "https://github.com/jardarton/seter.git";
    network = {
      address = "10.100.0.10";
      mac = "02:00:00:00:02:10";
      tap = "seter-phase2";
    };
    resources = {
      memoryMiB = 4096;
      vcpu = 4;
      cpuQuotaPercent = 400;
    };
    ssh.authorizedKeys = [ (builtins.readFile ./operator-key.pub) ];
  };
};
```

Use a temporary operator key dedicated to this acceptance run. Keep its private
half on the macOS Client and load it into the macOS agent; place only the public
half beside the temporary trusted configuration.

The Workspace must trust the actual Seter proxy CA before repository bootstrap.
Use a two-stage deployment if necessary:

1. deploy the Host and allow `seter-proxy.service` to create its persistent CA;
2. export the public certificate with `seter proxy-ca` into the Client Exchange
   Directory;
3. review it and set `seter.host.proxyCaCertificate = builtins.readFile
   ./seter-proxy-ca-cert.pem`; and
4. redeploy with the Phase 2 Workspace.

Do not copy the proxy CA private key or the Workspace SSH private key into the
consumer configuration, exchange directory, or Nix store.

The temporary configuration is acceptance infrastructure, not the reusable
`limaHost` module or consumer-flake example planned for Phase 3.

## 3. Verify deployed Host and Runner invariants

After deployment and before first boot, verify:

```sh
uname -m
uname -r
systemctl cat seter-vm-phase2.service
systemctl cat seter-runtime-phase2.target
systemctl show -p User -p Group -p MemoryMax -p CPUQuotaPerSecUSec \
  seter-vm-phase2.service
```

Expected results:

- the Host architecture is `aarch64` and its kernel is 6.12 LTS;
- the VM service runs as its dedicated `seter-*` account;
- the VM service has one `LoadCredential=` entry sourcing only that Workspace's
  root-owned SSH host key;
- the runtime target depends directly on `seter-tap-phase2.service`;
- no `seter-identity-virtiofsd-phase2.service` exists;
- `/dev/kvm`, `/dev/net/tun`, `/dev/vhost-net`, and `/dev/vhost-vsock` remain
  the only allowed VM devices; and
- memory and CPU controls match the declared resources.

Inspect `/etc/seter/runners/phase2/bin/microvm-run` and confirm the same command
properties enforced by the ARM build check. Confirm the credential path appears
but no private-key bytes do.

## 4. Exercise the ordinary Seter lifecycle

Enter the Seter Host through an SSH connection that forwards the temporary
macOS agent only to the trusted Host. Confirm `SSH_AUTH_SOCK` is set there.
Then use only public Seter commands:

```sh
seter status phase2
seter init phase2
seter status phase2
seter ssh-host-key phase2
seter run phase2 -- uname -m
seter run phase2 -- uname -r
seter run phase2 -- nproc
seter shell phase2
```

Expected guest values are `aarch64`, Linux 6.12 LTS, and four CPUs. In the
interactive shell verify `SSH_AUTH_SOCK` is absent: the macOS agent must not be
forwarded onward into the Workspace.

Create persistence evidence without placing credentials in the guest:

```sh
seter run phase2 -- sh -lc 'printf project > ../phase2-project-marker'
seter run phase2 -- sh -lc 'printf home > ~/phase2-home-marker'
seter run phase2 -- sh -lc \
  'printf store > /tmp/phase2-store-marker && nix store add-file /tmp/phase2-store-marker > ~/phase2-store-path'
```

Also verify the Store View and network boundary:

- `/` is tmpfs;
- Project, Home, and `/nix` are separate ext4-backed persistent volumes;
- `/nix/store` is the private writable overlay over the Runner's filtered
  read-only Store View;
- an unrelated Host store sentinel is not visible;
- the approved repository remains reachable; and
- an undeclared destination is denied and appears as a Policy Observation.

Test Workspace restart persistence:

```sh
seter down phase2
seter status phase2
seter up phase2
seter run phase2 -- sh -lc '
  test "$(cat ../phase2-project-marker)" = project
  test "$(cat ~/phase2-home-marker)" = home
  store_path=$(cat ~/phase2-store-path)
  test "$(cat "$store_path")" = store
'
```

Then test Seter Host persistence:

1. `seter down phase2`;
2. stop and start the Lima instance without deleting it;
3. reconnect with the agent forwarded to the trusted Host;
4. run `seter up phase2`; and
5. repeat all three persistence checks.

Record launch-to-authenticated-SSH time for first boot and restart. A regression
toward the previous 221-second virtiofs result blocks acceptance.

## 5. Negative identity checks

While the Workspace is running, verify:

- the unprivileged guest user cannot read
  `/run/seter-identity/ssh_host_ed25519_key`;
- the unprivileged guest user cannot read the raw fw_cfg credential under
  `/sys/firmware/qemu_fw_cfg/by_name/opt/io.systemd.credentials/`;
- the public key derived inside the guest exactly matches
  `seter ssh-host-key phase2`;
- strict host-key checking rejects a substituted key; and
- stopping the Workspace removes the TAP and private runtime credential
  directory without deleting the persistent identity or volume images.

A missing credential, permissive key mode, identity mismatch, readable raw
credential, or dependency on an identity virtiofs service is a blocker.

## 6. Native-Linux regression

After any fixes from the physical run, return to `x86_64-linux` and run:

```sh
cargo test
cargo clippy
nix build .#seter
nix flake check
```

Do not pass `--all-systems`. Confirm the native Runner still defaults to Cloud
Hypervisor and its read-only identity virtiofs service, and that the existing
nested lifecycle, host runtime, proxy, storage, SSH, and network-policy checks
pass.

## 7. Acceptance record

Add `docs/acceptance/macos-phase2-<date>.md` containing:

- Seter revision;
- hardware, macOS, Lima, QEMU, NixOS, and both kernel versions;
- Host CPU, memory, and disk allocation;
- all ARM build outputs and results;
- generated QEMU command properties without credential contents;
- first and restart SSH-readiness times;
- lifecycle and three-volume persistence results;
- negative identity and agent-forwarding results;
- native `x86_64-linux` regression results; and
- every remaining limitation or unexplained warning.

Update the roadmap only after this record exists. Phase 2 is complete when the
ARM build set, ordinary CLI lifecycle, identity channel, storage persistence,
network boundary, and native-Linux regressions all pass with no architectural
workaround.
