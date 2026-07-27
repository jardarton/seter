# Configuration ownership

**Status:** accepted design for the first usable milestone. That milestone's generic `default` Guest Profile path is not yet implemented; the current vertical slice expects a project-owned runner that imports Seter's generated guest identity. The future specialized-workload model remains unresolved.

Seter separates configuration by authority. A repository's development environment is not the same thing as the host policy that contains it or the guest operating system that runs it.

## First-milestone layers

| Layer | Owner | Defines | Must not define |
| --- | --- | --- | --- |
| Workspace Registry | Trusted infra | Repository source, workspace identity, resource limits, credential bindings, selected Guest Profile, and effective Policy Grants | Project development commands |
| Policy File | Trusted infra | Consumer-owned, reviewable network and host-capability grants merged into the Workspace Registry | Real credentials or project development commands |
| Guest Profile | Trusted infra or Seter | Reusable guest packages, services, agents, and baseline bootstrap capabilities | A specific repository's source or host policy |
| Development flake | Project repository | The development shell and project dependencies | Host or guest security policy |

The Workspace Registry and host enforcement are authoritative. Repository code and its development flake are untrusted workload input.

## Default-profile path

This is the only onboarding path required for the first usable milestone:

1. The Workspace Registry approves one HTTPS repository source and selects the trusted `default` Guest Profile.
2. Seter builds a runner entirely from trusted configuration.
3. `seter init` creates the workspace and checks out the approved repository under `/project/<repository>`.
4. The user explicitly approves the repository's `.envrc` before its development flake executes.

A repository does not need Seter-specific NixOS configuration. The `default` profile provides Nix, Git, SSH tooling, direnv/nix-direnv, and baseline shell utilities. Agent packages may be supplied by trusted consumer-owned profiles, while Seter core remains agent-agnostic.

## Why arbitrary project modules are not “extension only”

NixOS module assertions can catch conflicting option values, but an arbitrary repository-owned module can add root services or activation scripts that mutate guest behavior after boot. It can therefore disable or replace guest SSH, bootstrap, or other internal behavior even if direct option overrides are rejected.

The host boundary still contains such a guest: host-owned network policy, resource limits, lifecycle privilege separation, and credential bindings remain authoritative. But Seter must not describe arbitrary project Nix as unable to replace the trusted guest baseline.

## Future specialized workloads

The initial milestone deliberately defers specialized guest composition. A later decision may choose one or more explicit models:

- a restricted capability schema translated into trusted NixOS configuration;
- trusted custom Guest Profiles maintained in consumer infra;
- an advanced project-owned runner path documented as fully project-controlled and untrusted inside the VM boundary.

No future model should be called “extension only” unless Seter exposes a genuinely restricted interface rather than an arbitrary NixOS module.

## Why the distinction matters

Calling every layer a “workspace flake” hides who is trusted and makes ordinary project adoption unnecessarily invasive. The trusted default path optimizes routine adoption without pretending that arbitrary repository-owned operating-system code can be safely constrained through module composition alone.
