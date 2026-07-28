# Roadmap

## Objective

Reach the first genuinely usable Seter milestone: one repository in one trusted-profile workspace on a native NixOS host, suitable for normal development and agent work, with default-deny policy that an operator can review and widen safely.

The milestone requires both automated KVM evidence and a private real-project trial. Personal repositories, hosts, policy, credentials, and infra paths never enter this public repository; only generalized defects and testable product behavior do.

Breaking changes are allowed. The current APIs have no compatibility or migration requirement.

## What the current vertical slice proves

The existing implementation provides substantial machinery worth preserving and adapting:

- host/guest identity projection and evaluation assertions;
- unprivileged VM execution behind narrow privileged lifecycle operations;
- bridge, TAP, IPv4/MAC anti-spoofing, and cross-workspace isolation;
- exact-name DNS enforcement and audit events;
- transparent intercepted HTTP/HTTPS and TLS passthrough;
- exact direct-TCP grants and approved host-daemon relays;
- destination-bound header secret injection and exact-value response redaction;
- a private writable Nix-store overlay and persistent guest Nix database;
- strict SSH client behavior;
- Nix evaluation checks, adversarial network tests, and nested-KVM lifecycle coverage.

This proves an early security vertical slice, not a usable project onboarding workflow. No real project has yet been initialized or used by the intended user.

## First usable milestone

### 1. Replace the workspace and Runner model

**Status: implemented.** The trusted registry, default-profile host deployment, closure rooting, version 5 lifecycle projection, and no-evaluation cold-start path are covered by evaluation and KVM checks.

- Remove the compatibility `mkWorkspace` path and project-installable-based default workflow.
- Define one trusted Workspace Registry schema containing:
  - one approved HTTPS repository URL;
  - optional initial branch;
  - URL-derived checkout name with optional override;
  - workspace identity and resource limits;
  - selected Guest Profile, initially only `default`;
  - credential bindings and effective Policy Grants;
  - Project, Home, and private Nix-store volume settings.
- Build, install, and root each default-profile Runner as part of trusted NixOS host deployment.
- Remove `seter update` from the default workflow.
- Keep cold starts free of Nix evaluation.

Evidence: evaluation tests prove registry invariants, host/Runner identity alignment, closure rooting, duplicate rejection, and atomic host deployment behavior.

### 2. Close foundational storage and identity gaps

**Status: implemented.** Host-created Workspace SSH Identities, closure-filtered Runner Store Views, and all three persistent volumes are covered by evaluation and adversarial KVM checks.

- Generate each Workspace SSH Identity in root-owned host state before first boot.
- Supply that identity to the guest and use its public half for strict client verification.
- Replace the whole-host-store export with fail-closed, closure-specific Store Views carried by deployed and retained Runners, reconciling the persistent guest database whenever the selected view changes.
- Add a persistent Home Volume while retaining separate Project and private Nix-store volumes.
- Ensure a workspace cannot enumerate a sentinel path placed elsewhere in the host Nix store.

Evidence: adversarial KVM tests prove strict SSH identity, absence of unrelated host-store paths, persistence of all intended state, and no writable path to the host store.

### 3. Implement the trusted `default` Guest Profile

**Status: implemented.** Host-deployed Runners provide the flake-enabled Nix
toolchain, system HTTPS trust, Git and SSH, explicit direnv/nix-direnv Bash
integration, and a small interactive utility baseline. Evaluation and KVM
checks exercise the profile with a repository containing only a development
flake and `.envrc`.

The first profile includes only:

- Nix and the private writable-store machinery;
- Git and HTTPS CA support;
- OpenSSH client/server tooling required by Seter;
- direnv and nix-direnv with shell integration;
- baseline interactive shell utilities.

Seter core remains agent-agnostic. Trusted consumer-owned profiles may eventually package agents, but additional public profiles and specialized composition are deferred.

Evidence: a repository with only a normal development flake can use Seter without containing Seter-specific NixOS configuration.

### 4. Implement safe Workspace Bootstrap

Add `seter init <workspace>` with this contract:

- require the Runner installed by successful host deployment;
- create missing host identity and persistent volumes;
- start the workspace and leave it running;
- clone the single approved repository under `/project/<checkout-name>`;
- use the remote default branch unless the registry selects one;
- use an exact-host and exact-repository-path HTTPS credential binding when configured;
- support read/write Git authority for the approved repository without exposing the credential to the guest;
- never support SSH Git in this milestone;
- never execute or approve `.envrc`;
- safely retry an absent, complete, or recoverable partial bootstrap;
- never delete, clean, reset, or overwrite existing working data;
- reject unrelated content or a mismatched remote with a direct explanation.

Evidence: an authenticated local HTTPS Git fixture exercises clone, fetch, and push; unauthorized repository paths fail; the credential cannot be read from the guest; repeated initialization is non-destructive.

### 5. Complete the daily lifecycle

- `seter shell` starts when needed, enters the registered checkout, and leaves the VM running.
- `seter run -- <command>` starts when needed, runs from the same checkout, propagates the exit code, and leaves the VM running.
- `seter up` remains useful for explicitly starting background workloads.
- `seter down` remains the only routine automatic shutdown trigger.
- `shell` and `run` explain that explicit `direnv allow` is required instead of silently evaluating repository code.
- `status`, `list`, and `ip` report the deployed model consistently.

Evidence: lifecycle tests cover stopped and running entry, cwd, exit-code propagation, persistence, SSH failure, and interrupted commands.

### 6. Make default-deny policy operable

- Define and import the consumer-owned TOML Policy File.
- Support exact Host Patterns and explicit single-label wildcards for intercepted HTTP and TLS passthrough.
- Reject recursive syntax, apex implication, public/shared-hosting suffix wildcards, and HTTP/passthrough overlap.
- Keep direct TCP and every credential binding exact-host only.
- Add workspace-scoped `seter audit` without granting operators broad host-journal access.
- Add interactive `seter policy review --file ...`:
  - group observations;
  - distinguish evidence from ambiguous DNS-only traffic;
  - never infer wildcard or credential grants;
  - display and confirm an exact diff;
  - validate, lock, and atomically update the Policy File;
  - never deploy or create mutable runtime exceptions.
- Add desired-versus-active `seter policy status` and make revocation available through the same review surface.

Evidence: tests cover malicious observation floods, wildcard boundaries, ambiguous traffic, cross-workspace audit isolation, interrupted file edits, pending deployment, revocation, and the impossibility of guest self-approval.

### 7. Add safe reset and retirement operations

- Implement stopped-workspace reset for Home, private Nix store, or both.
- Define `--all-state` as Home plus private Nix store, never Project Volume.
- Preserve Workspace SSH Identity, deployed Runner, registry, and policy across reset.
- Implement `seter gc` for unreachable Runner roots and explicitly replaceable host artifacts only.
- Identify retained orphaned state after Workspace Retirement.
- Keep Project Volume destruction a separate, strongly confirmed operation with dirty/unpushed-state warnings where inspectable.

Evidence: destructive-operation tests use sentinel working data and prove that reset and GC cannot remove it.

### 8. Verify the product rather than only the components

The automated native-NixOS KVM scenario must cover this complete sequence:

1. deploy a trusted default-profile Runner;
2. initialize from an authenticated HTTPS repository;
3. verify strict SSH and closure-filtered store visibility;
4. inspect denied policy and approve a declarative grant;
5. deploy the grant and verify desired/active agreement;
6. explicitly approve direnv;
7. use `shell` and `run`;
8. fetch and push Git changes;
9. restart and verify Project, Home, and private-store persistence;
10. reset reproducible state without touching the working tree;
11. stop and retire safely.

After automated success, perform a private real-project trial involving normal development and agent work. Record only generalized product defects publicly. The milestone is not complete until that workflow is comfortable enough to repeat rather than merely possible once.

## Explicitly deferred

- macOS/Lima and nested host deployment;
- Docker and additional public Guest Profiles;
- arbitrary project-owned NixOS modules or a specialized capability schema;
- multi-repository workspaces;
- SSH Git transport;
- wildcard direct TCP;
- automatic `.envrc` approval;
- mutable or automatically learned runtime policy;
- Herdr integration and remote agent restoration;
- disposable/snapshotted command workspaces;
- automatic Project Volume deletion.

## Completion criteria

The first usable milestone is complete only when:

- all automated checks, including the full KVM workflow, pass from a clean checkout;
- the packaged NixOS host and Runner deployment works through the public API;
- no guest can read unrelated host-store sentinel paths;
- no real repository credential is observable in the guest or injected outside its exact repository path;
- policy grants require explicit operator review and declarative host deployment;
- reset and GC preserve working-tree sentinels;
- public documentation clearly separates implemented behavior, accepted design, and deferred work;
- a private real-project and agent trial completes successfully, with resulting generalized blockers fixed or consciously deferred outside the milestone.
