# Lifecycle authorization

Seter separates an operator-facing command from the small operation that must be authorized by the host. A VM does not run as root, but starting it asks the system systemd manager to create privileged network plumbing and control root-owned units.

## Operator model

The host module creates `seter.host.operatorGroup` (`seter-operators` by default). Add trusted users explicitly:

```nix
users.users.alice.extraGroups = [ "seter-operators" ];
```

Membership grants permission to start and stop every workspace registered on that host. It does not grant general sudo or systemd access. Registry and Runner changes occur only through trusted NixOS deployment. Offline project-image access remains a separately privileged operation.

## Two-stage command

An ordinary invocation such as:

```console
seter up project
```

uses `sudo` only for a hidden internal operation:

```text
seter up project
  -> sudo -- /nix/store/...-seter/bin/seter __start project
  -> systemctl start seter-vm-project.service
```

`seter down` similarly delegates to `__stop`. The NixOS module generates passwordless sudo rules for each exact operation and configured workspace. It does not use a wildcard and does not authorize arbitrary `seter` or `systemctl` commands.

The internal commands are implementation details, not a user-facing API. Hiding them from CLI help is only a usability measure; authorization comes from sudoers and privileged revalidation.

## Privileged-side requirements

The privileged operation must:

1. require root (except in explicitly isolated test state);
2. discard environment overrides used by unprivileged tests;
3. reload `/etc/seter/workspaces.json` after elevation;
4. reject names absent from that root-owned registry;
5. construct the fixed systemd unit name itself; and
6. invoke systemd without a shell.

Checks performed before elevation are never treated as authorization. The generated systemd service launches `microvm-run` and `microvm-shutdown` as the workspace's dedicated `seter-*` account. Root authorizes orchestration but does not execute project runner code.

## Scope

These commands remain unprivileged:

- `seter list`
- `seter ip`
- `seter status`
- `seter shell`
- `seter run`

There is no CLI Runner-install privilege. Before each cold start, the privileged path parses the deployed Runner's bounded regular-file identity manifest and compares it with the root-owned registry without executing Runner code or evaluating Nix. The manifest is consistency metadata, not attestation; host-side isolation does not trust it. `seter ssh-host-key` separately elevates offline access to the host-owned Project Volume. That operation is not included in the lifecycle operator group's passwordless start/stop grant.
