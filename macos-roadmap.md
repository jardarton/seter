# macOS Integration Roadmap

## Status

macOS integration is designed but not implemented. The current Seter host and
Runner lifecycle are Linux-only, and the full VM checks run only on
`x86_64-linux`.

This roadmap targets the first, deliberately manual level of integration: a
repeatable documented deployment using a checked-in Lima template and a
consumer-owned flake. A native Darwin CLI and transparent Lima management are
future improvements.

## Objective

On one eligible macOS Client, run one trusted Seter Host as an `aarch64-linux`
NixOS instance under Lima's `vz` backend. The Seter Host must run the existing
Seter policy and Workspace stack through nested virtualization and support the
complete current development workflow.

The first milestone optimizes for proving and documenting the architecture, not
for hiding it. Operators start Lima explicitly and invoke Seter inside the Seter
Host.

## Supported platform

The initial support boundary is intentionally narrow:

- Apple Silicon M3 or newer;
- macOS 15 or newer;
- one Seter Host per macOS Client;
- one explicitly configured, read-write Client Exchange Directory;
- Nix and Lima installed on the macOS Client;
- explicit Seter Host startup and explicit command execution through Lima.

Intel Macs, M1/M2 Macs, older macOS releases, and software-emulated nested
virtualization are unsupported. There is no fallback architecture for those
machines.

## Architecture and trust boundaries

```text
macOS Client
├── Nix
├── Lima
├── consumer flake
└── Client Exchange Directory (read-write)
    │
    ▼
Seter Host: NixOS under Lima/vz
├── trusted Workspace Registry and Policy File
├── Seter host services and CLI
├── persistent Workspace storage
└── nested KVM VMM
    │
    ▼
Workspace
└── repository and development workload
```

The Seter Host is trusted in the same way as a physical NixOS Seter host. It
owns policy, credentials, storage, and Workspace lifecycle. It is not treated
as an untrusted intermediary merely because it is virtualized.

The Client Exchange Directory may contain the consumer flake, allowing
`seter policy review` on the Seter Host to edit the consumer-owned Policy File
directly. It must not be mounted into a Workspace. Project Volumes, Home
Volumes, private Nix-store volumes, builds, and working trees remain on the
Seter Host's virtual disk rather than the shared directory.

### Initial SSH identity bridge

The manual integration forwards the macOS operator's SSH agent into the Seter
Host. `seter shell` and `seter run` may use that agent to authenticate to a
Workspace, while Seter continues to disable forwarding the agent onward into
the Workspace.

This differs from native NixOS operation and is a known provisional bridge:

- the trusted Seter Host can use the agent while it is forwarded;
- commands depend on the agent and Lima forwarding the socket correctly;
- the mechanism is unsuitable for unattended operation;
- no private operator key needs to be persisted in the Seter Host.

The implementation must test and document this behavior. A dedicated
Seter-managed operator identity remains a possible future replacement.

## Required deliverables

### Lima template

Ship a checked-in Lima template that:

- uses a pinned minimal `aarch64-linux` NixOS base image with verified digest;
- selects the `vz` backend and enables nested virtualization;
- creates one persistent Seter Host;
- exposes configurable CPU, memory, and disk sizing with documented defaults;
- mounts exactly one selected Client Exchange Directory read-write;
- does not mount the macOS home directory broadly;
- provides bootstrap SSH access suitable for remote NixOS deployment;
- preserves the virtual disk across ordinary stop/start and macOS reboot.

The base image is only a bootstrap environment. The consumer's trusted NixOS
configuration replaces it through normal deployment.

### Reusable NixOS module

Expose a module such as `seter.nixosModules.limaHost` that composes:

- the existing Seter host module;
- Lima guest integration required for SSH and the exchange directory;
- nested-KVM prerequisites;
- networking needed by nested Workspaces;
- safe outer-host defaults.

The module must not own consumer authority. The consumer flake continues to own
users, the Workspace Registry, Policy Grants, secret-file sources, resource
choices, and other site configuration.

### Consumer-flake example

Provide a minimal external consumer flake showing:

- `aarch64-linux` NixOS configuration;
- import of `seter.nixosModules.limaHost`;
- one Workspace;
- operator SSH authorization;
- a consumer-owned Policy File;
- remote build and deployment into the bootstrap Seter Host;
- use of the Client Exchange Directory for direct policy review.

The macOS Client must be able to evaluate the flake while the Seter Host builds
its own Linux closures. Remote builders and private binary caches may be used by
consumers but are not prerequisites.

### Operator documentation

Document the exact manual workflow:

1. verify hardware and operating-system eligibility;
2. install Nix and Lima;
3. select the Client Exchange Directory;
4. create and start the Seter Host from the checked-in template;
5. deploy the consumer flake remotely;
6. forward the operator SSH agent;
7. invoke Seter explicitly through Lima;
8. open a macOS-local SSH tunnel to a Workspace service when needed;
9. stop and restart the Seter Host safely;
10. update the Seter Host by redeploying the consumer flake.

The documentation must prominently state that deleting the Lima instance
destroys all Workspaces and their persistent volumes. Backup and restore are not
part of this milestone.

## Delivery phases

### Phase 1: Hardware feasibility gate

Perform this phase first on an eligible physical Mac. Do not build higher-level
launcher behavior before it passes.

Prove:

- the pinned NixOS base image boots under Lima/vz;
- nested virtualization exposes usable KVM to the Seter Host;
- an `aarch64-linux` inner VM boots;
- TAP, bridge, nftables, DNS, and outbound networking work through both layers;
- persistent disks and required filesystem behavior work under Lima;
- interactive SSH and agent forwarding survive the Mac-to-Seter-Host hop.

Try the existing Cloud Hypervisor path first. QEMU/KVM is an acceptable
ARM-specific fallback only if equivalent lifecycle, isolation, storage,
networking, and policy properties are demonstrated. If QEMU becomes the chosen
path, record the evidence and architectural trade-off in an ADR.

If neither VMM works reliably, stop and revise the architecture rather than
building wrappers around a failed foundation.

### Phase 2: Make the Seter stack work on `aarch64-linux`

- Build the CLI, host configuration, guest configuration, and Runner for ARM.
- Find and remove accidental `x86_64-linux` assumptions.
- Enable architecture-independent checks on ARM where practical.
- Add ARM coverage for Runner construction and VMM-specific configuration.
- Preserve the existing strict SSH, storage, lifecycle, and network-policy
  semantics.
- Keep native `x86_64-linux` behavior and tests passing.

This phase does not add an `aarch64-darwin` Seter executable. Seter commands
continue to execute inside the Seter Host.

### Phase 3: Build repeatable bootstrap and deployment artifacts

- Add the pinned Lima template.
- Add `nixosModules.limaHost` or its final equivalent.
- Add the external consumer-flake example.
- Establish remote deployment from Nix on macOS to the bootstrap Seter Host.
- Build Linux closures on the Seter Host to avoid a cross-platform bootstrap
  dependency.
- Verify that deployment does not replace the Lima data disk or persistent
  Workspace state.
- Document recovery from an interrupted deployment without promising recovery
  from deletion or disk corruption.

### Phase 4: Complete manual operator integration

- Document explicit `limactl start` and `limactl shell` command forms.
- Verify interactive TTY behavior, signals, and exit-status propagation.
- Verify the forwarded operator agent can authenticate to Workspaces and is not
  forwarded onward.
- Run `seter policy review` against the Policy File in the Client Exchange
  Directory and redeploy the resulting consumer configuration.
- Document explicit loopback-only SSH tunnels from macOS to Workspace services.
- Keep direct routing, subnet routing, Tailscale, and automatic tunnel
  management out of scope.

### Phase 5: Prove the complete Seter workflow

On the physical Mac, exercise the same product behavior expected on native
NixOS:

1. deploy a trusted default-profile Runner;
2. initialize an authenticated HTTPS repository;
3. verify strict Workspace SSH identity and filtered Store View behavior;
4. observe a denied network request;
5. review and write a declarative Policy Grant from the Seter Host;
6. redeploy and verify desired/active policy agreement;
7. explicitly approve direnv;
8. use interactive `shell` and non-interactive `run`;
9. fetch and push repository changes;
10. reach a Workspace development service through a macOS loopback tunnel;
11. restart the Workspace and verify Project, Home, and private-store
    persistence;
12. reset reproducible state without damaging the Project Volume;
13. stop and retire the Workspace safely.

Also prove outer lifecycle persistence:

- stop and restart the Seter Host;
- reboot the macOS Client, manually restart the Seter Host, and reconnect;
- deploy an updated consumer-flake generation;
- after each operation, verify Workspace Project, Home, and private Nix-store
  state remains intact.

A running Workspace does not need snapshot/resume semantics. It may return as
stopped after an outer restart, provided `seter up` starts it cleanly with its
persistent state.

### Phase 6: Measure and document operability

Record, at minimum:

- Seter Host cold-start time;
- Workspace cold-start time;
- time to enter `seter shell`;
- a representative Nix build;
- basic filesystem-I/O behavior;
- CPU and memory allocation used for the measurements;
- VMM, Lima, NixOS, macOS, and hardware versions.

The first milestone has no fixed performance threshold. Results that make
ordinary development clearly impractical remain a blocker requiring an
explicit decision rather than being hidden behind functional success.

## Acceptance evidence

Ship a checked-in acceptance script for the repeatable portions of the workflow.
It must be run successfully on a real M3-or-newer Mac with macOS 15 or newer,
and the environment, result, and performance measurements must be recorded.

A permanent self-hosted Mac CI runner is not required. Linux evaluation, Rust,
and architecture-independent checks should remain automated in normal CI; the
nested macOS acceptance run is a recorded manual release gate until suitable CI
exists.

## Completion criteria

The initial macOS integration is complete only when:

- all Phase 1 feasibility checks pass on supported hardware;
- a clean eligible Mac can follow the documentation using checked-in artifacts;
- the consumer flake deploys without requiring another Linux machine;
- the current complete Seter workflow passes on an ARM Workspace;
- policy review and redeployment work through the Client Exchange Directory;
- operator SSH-agent behavior and its trust implications are documented;
- a macOS browser can reach a Workspace service through an explicit loopback
  tunnel;
- ordinary Seter Host stop/start, macOS reboot, and configuration redeployment
  preserve all Workspace volumes;
- native NixOS behavior and checks remain passing;
- the acceptance record and performance measurements are checked in;
- unsupported hardware and destructive Lima operations fail clearly or are
  prominently documented.

## Explicitly out of scope

- a Darwin build of the `seter` CLI;
- transparent or managed command forwarding;
- automatic Seter Host creation, startup, repair, or upgrade;
- launchd/login startup;
- more than one Seter Host per macOS Client;
- M1, M2, Intel, or pre-macOS-15 support;
- broad macOS home-directory sharing;
- direct Client Exchange Directory access from a Workspace;
- transparent routing to Workspace addresses;
- Tailscale integration;
- automatic service-tunnel management;
- required remote builders or binary caches;
- backup and restore;
- recovery after `limactl delete` or virtual-disk corruption;
- USB passthrough and macOS device-daemon integration;
- unattended operation using the forwarded operator agent.

## Future improvements

After the documented deployment is stable:

1. **Managed but visible integration** — add a native macOS client that talks to
   an explicitly user-managed Seter Host, forwards commands and signals, and
   manages service tunnels.
2. **Transparent integration** — let Seter provision, start, update, diagnose,
   and repair Lima while preserving an ordinary `seter` command experience.
3. Replace forwarded operator-agent dependence with a purpose-built,
   narrowly-scoped identity mechanism if testing or unattended workflows
   justify it.
4. Add transparent routing or deliberate Tailscale integration.
5. Add backup/restore, remote-builder configuration, automatic startup, and
   multi-host management where real usage demonstrates a need.
