# Workspace storage lifecycle

**Status:** accepted product design; separate persistent Home storage and reset commands are not yet implemented. The current vertical slice persists a Project Volume and private Nix-store volume while guest home state remains ephemeral.

A workspace has three persistent storage classes with different safety contracts.

## Project Volume

The Project Volume contains the approved repository checkout under `/project/<repository>`. It is durable working data and may contain dirty or unpushed changes. Garbage collection and Workspace Reset never remove or recreate it.

Deleting a Project Volume is a separate destructive action with strong confirmation. Workspace Retirement retains it by default.

## Home Volume

The Home Volume is mounted as the workspace user's home and contains shell history, editor state, direnv approvals, language-tool caches, user configuration, and similar daily development state. It belongs only to that workspace and never contains an ambient host-home mount.

Home state is persistent but reproducible enough to reset deliberately when configuration becomes corrupt or compromised.

## Private Nix-store volume

The private Nix-store volume contains the writable overlay above the shared read-only host store and the guest Nix database. It persists project-built and substituted derivations across clean-root reboots. Replacing the volume is the supported way to reclaim its capacity because stock guest garbage collection can create overlay whiteouts for shared lower-store paths.

## Reset

Reset requires a stopped workspace and always presents the selected storage before confirmation:

```console
seter reset <workspace> --home
seter reset <workspace> --nix-store
seter reset <workspace> --all-state
```

`--all-state` means Home plus private Nix store. It never includes the Project Volume. Non-interactive reset requires an explicit `--yes` flag.

Reset preserves:

- the Project Volume and repository working tree;
- the host-created Workspace SSH Identity;
- Workspace Registry identity and Policy Grants;
- the deployed Runner.

Resetting Home removes direnv approvals and user configuration. Resetting the private Nix store removes guest-built dependencies and its Nix database, so the next development activation rebuilds or substitutes them.

## Garbage collection and retirement

`seter gc` removes unreachable Runner roots and other explicitly replaceable host artifacts. It does not remove Project Volumes.

Workspace Retirement stops active use and identifies retained state after registry removal. A separate explicit destruction workflow may later remove a retained Project Volume after warning about inspectable dirty or unpushed Git state. Retirement, reset, garbage collection, and destruction are distinct operations.
