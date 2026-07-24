# Herdr integration design note

**Status:** exploratory design; not implemented

This note records the current design discussion for integrating [Herdr](https://github.com/ogulcancelik/herdr) with Seter. It describes intended behavior, security constraints, feasible integration levels, and unresolved work. It is not a description of functionality that Seter currently provides.

## Goal

Run one Herdr server on the host and associate each Herdr workspace with one Seter workspace VM. All shells, agents, test runners, and development servers shown in that Herdr workspace should execute inside the associated VM.

```text
Host Herdr
├── workspace: project-a ──> Seter VM: project-a
│   ├── pane: Pi
│   ├── pane: tests
│   ├── pane: server
│   └── pane: shell
├── workspace: project-b ──> Seter VM: project-b
│   ├── pane: Pi
│   └── pane: shell
└── workspace: project-c ──> Seter VM: project-c
```

The intended user experience is:

- Herdr remains the single host-side interface and agent dashboard.
- A Herdr workspace is the UI representation of a Seter workspace.
- Splitting or creating a pane in that workspace opens another connection to the same VM.
- Agents and project code run inside the VM, not on the host.
- Herdr can display and coordinate agents across all project VMs.
- The VM remains a meaningful isolation boundary even when agent integrations are enabled.

## Current building blocks

### Seter

Seter already has the relevant underlying workspace abstraction:

- a durable workspace name from the host registry;
- a dedicated VM and persistent project volume per workspace;
- explicit `seter up`, `seter shell`, `seter status`, and `seter down` lifecycle operations;
- strict SSH host-key checking;
- no SSH agent or X11 forwarding;
- fixed, host-authorized VM lifecycle operations.

Seter does not currently create Herdr workspaces, associate Herdr workspaces with VMs, proxy the Herdr API, or restore remote agent sessions.

### Herdr

Herdr provides the host-side primitives needed for an initial integration:

- workspaces, tabs, and terminal panes;
- a background server that keeps pane PTYs alive when the UI detaches;
- CLI and newline-delimited JSON socket APIs;
- agent screen detection and lifecycle state rollups;
- agent automation operations such as read, prompt, and wait;
- custom lifecycle and metadata reporting;
- `HERDR_AGENT=<agent>` hints for agents hidden behind VM or sandbox wrapper processes.

Herdr normally detects the foreground process attached to its PTY. With an SSH-based VM pane, the host-visible process is `ssh`, not the agent in the guest. A host-visible hint allows Herdr to apply the appropriate screen manifest:

```sh
HERDR_AGENT=pi ssh -tt project-a-vm \
  'cd /project && exec pi'
```

The hint must be present on the host-visible wrapper process. Setting it only inside the VM is not visible to host Herdr.

Relevant upstream documentation:

- [How to work with Herdr](https://herdr.dev/docs/how-to-work/)
- [Agents and VM wrappers](https://herdr.dev/docs/agents/)
- [Integrations](https://herdr.dev/docs/integrations/)
- [Socket API](https://herdr.dev/docs/socket-api/)
- [Agent automation](https://herdr.dev/docs/agent-automation/)

## Baseline integration

The simplest useful implementation does not require Herdr inside the VM.

1. Run one Herdr server on the host.
2. Create a Herdr workspace with an explicit project label.
3. Start the associated Seter VM.
4. Run one SSH connection per Herdr pane.
5. Add `HERDR_AGENT=pi` to host-side launch commands for Pi panes.

An agent pane would be conceptually equivalent to:

```sh
HERDR_AGENT=pi ssh -tt project-a-vm \
  'cd /project && exec pi'
```

An ordinary shell pane would be equivalent to:

```sh
ssh -tt project-a-vm \
  'cd /project && exec bash -l'
```

This provides a unified terminal interface and screen-based agent detection. It does not provide authoritative Pi lifecycle hooks, remote session restoration, or safe VM-originated Herdr orchestration.

Host Herdr cannot inspect the guest process tree or reliably infer the guest working directory through host process inspection. Workspace and pane labels should therefore come from the Seter workspace binding rather than host-side cwd detection.

## Workspace-to-VM binding

The binding should use the durable Seter workspace name as its project identity. Herdr's public runtime workspace and pane IDs should not be treated as durable project identifiers.

A host-owned association could resemble:

```json
{
  "project-a": {
    "seterWorkspace": "project-a",
    "remoteCwd": "/project"
  }
}
```

The implementation could be a Seter command, a Herdr plugin, or a small host service used by both. It would be responsible for:

- creating or finding the Herdr workspace for a Seter workspace;
- starting the VM when explicitly requested;
- launching the root pane through the Seter SSH path;
- creating additional shell or agent panes in the same VM;
- applying stable labels and display metadata;
- retaining enough host-side state to reconcile bindings after restart;
- defining behavior when a pane is moved between workspaces;
- optionally stopping or suspending the VM when its Herdr workspace closes.

The binding must not rely only on a mutable workspace label. A durable host-side registry should associate Seter's workspace identity with the corresponding live Herdr workspace and reconcile that association when Herdr restarts.

### New panes

Every pane created in a VM-bound workspace should enter the associated VM. It must not silently become an unrestricted host shell.

Possible implementation approaches include:

1. Herdr plugin actions such as **new VM shell** and **new VM agent**.
2. A Seter launcher that creates panes through Herdr's API with fixed commands.
3. A pane-created event handler that replaces a fresh shell with the VM launcher.
4. A host default-shell dispatcher that recognizes VM-bound workspace context.

Explicit plugin or launcher actions are the least surprising initial design. Automatically replacing newly created shells risks races in which the host shell is briefly available. If ordinary Herdr split keybindings must work transparently, the final implementation needs a mechanism that selects the VM launcher before the pane process starts.

### Moving panes

A live pane cannot change the machine on which its current process runs merely by moving to another Herdr workspace. The integration must choose an explicit policy:

- reject moves between differently bound workspaces;
- close and relaunch the pane in the destination VM; or
- retain the pane's original VM identity and visibly mark the mismatch.

Rejecting the move is the safest initial behavior.

## Deeper integration without Herdr in each VM

Herdr does not need to run inside each VM. One host Herdr server can remain authoritative while a restricted gateway exposes selected API capabilities to agents in the VMs.

```text
Pi integration in VM A ─┐
Pi integration in VM B ─┼─> capability gateway ─> host Herdr socket
Pi integration in VM C ─┘
```

This is a centralized control plane with remote workers. It may be described informally as a federated socket, but it is not multi-server federation: there is only one Herdr server and one authoritative session.

### Why not forward the raw socket?

The Herdr socket is a control API, not a lifecycle-report-only endpoint. It can create panes, send terminal input, run commands, invoke plugins, and stop the server. A VM with unrestricted access could create or take over a host shell and thereby escape the intended isolation boundary.

Forwarding the host Herdr socket directly into an agent VM is therefore unacceptable for Seter's threat model. It may be convenient when a VM is used only for dependency cleanliness, but it does not provide the isolation Seter is intended to enforce.

### Capability gateway

The host should retain the real socket and expose a protocol-compatible proxy with explicit authorization. The gateway should authenticate the connection as a particular Seter workspace or pane and apply both method-level and resource-level policy.

Two capability scopes are useful.

#### Pane-scoped lifecycle endpoint

Each agent pane receives an endpoint bound to its actual Herdr pane. It may expose:

- `pane.report_agent`;
- `pane.report_metadata`;
- `pane.release_agent`;
- selected `pane.report_agent_session` behavior, once restoration is designed.

The gateway must not trust a client-supplied pane ID. It should replace it with, or verify it against, the pane bound to that connection. It should also validate the expected agent kind and reporting source where practical.

Inside the VM, the launcher would provide values equivalent to:

```sh
HERDR_ENV=1
HERDR_PANE_ID=w1:p1
HERDR_SOCKET_PATH=/run/user/1000/seter-herdr.sock
```

The official Pi Herdr extension already speaks Herdr's socket protocol. A protocol-compatible gateway would allow the extension to report authoritative `working`, `idle`, and `blocked` state without modification.

#### Workspace-scoped orchestration endpoint

A separate capability may allow agents to coordinate sibling agents in the same Seter workspace. Candidate operations include:

- filtered agent and pane listing;
- reading agents belonging to the same workspace;
- waiting for lifecycle state;
- prompting a recognized sibling agent;
- requesting creation of an approved agent or shell pane.

All list and event results must be filtered. A VM must not learn terminal contents, metadata, or session information from other Seter workspaces.

Raw process-launching methods should not be forwarded. Instead, the gateway should offer semantic operations such as `spawn-agent`. The host implementation would translate that request into a fixed sequence:

1. Verify the caller's Seter workspace capability.
2. Create a host Herdr pane in the associated Herdr workspace.
3. run the approved Seter/SSH launcher for the same VM;
4. start only an approved agent kind and argument set;
5. return the resulting filtered pane or agent identity.

This allows VM-originated orchestration without allowing arbitrary host commands.

### Methods that should not be directly exposed

At minimum, a VM should not receive unrestricted access to:

- `pane.run`;
- raw pane input for arbitrary targets;
- unrestricted pane, tab, workspace, or layout creation;
- arbitrary command or environment fields on process-launching methods;
- plugin installation or invocation;
- integration installation on the host;
- server stop, reload, or update operations;
- panes and agents belonging to another Seter workspace.

Even apparently harmless raw input methods can become host command execution if an SSH process exits and its pane returns to a host shell. Agent-level operations are safer when Herdr verifies that the intended recognized agent still occupies the target pane, but they must still be restricted to the caller's workspace.

### Transport

The guest needs a local endpoint that reaches the host gateway. Possible transports include:

- an SSH reverse-forwarded Unix socket;
- a VM-specific virtio-vsock service;
- a narrow authenticated TCP service on the host bridge.

The transport must preserve the workspace or pane capability and must not expose the real Herdr socket path. A per-connection, pane-bound endpoint is the strongest default for lifecycle reporting. A separate workspace-bound credential can be used for orchestration.

The final transport must be reviewed alongside Seter's unfinished host network policy. This design note does not claim that the current host networking implementation enforces the proposed gateway boundary.

## Agent state and session identity

Lifecycle state and native session restoration are separate concerns.

### Lifecycle state

Relaying Pi lifecycle reports is straightforward. The Pi extension can report semantic states through the restricted gateway:

- `working`;
- `idle`;
- `blocked`.

These states support Herdr's sidebar rollups, notifications, prompts, and waits more accurately than screen detection alone. Screen detection with `HERDR_AGENT=pi` remains a useful fallback.

### Session identity

The Pi integration can also report a session path or ID. A session path produced inside a VM belongs to the VM filesystem. Host Herdr's native cold-restore behavior would ordinarily attempt a host command equivalent to:

```sh
pi --session /path/inside/the/vm
```

That is incorrect: both the executable and path belong inside the associated VM.

Until remote-aware restoration exists, the gateway should strip or avoid persisting guest session references while continuing to forward lifecycle state. This prevents host Herdr from attempting an invalid or unsafe native restore.

A later restoration design can use the workspace binding:

```text
saved Herdr workspace
  -> durable Seter workspace identity
  -> start the corresponding VM
  -> reconnect a pane through the approved launcher
  -> run Pi inside the VM with the saved remote session reference
```

This likely requires a Seter-aware Herdr plugin, a configurable remote resume launcher in Herdr, or an upstream Herdr feature. A host executable shim that imitates `pi --session` could route restoration into a VM, but it would be fragile and could interfere with normal host Pi launches; it is not the preferred design.

## Persistence behavior

Several kinds of persistence must be distinguished:

- **Herdr client detach:** the host Herdr server retains the SSH PTY and the VM agent continues normally.
- **Network interruption:** the SSH connection may fail even though the VM and agent remain alive.
- **VM shutdown:** the guest agent process stops unless the VM itself is resumed from a snapshot, which is not a Seter goal.
- **Herdr server cold restart:** host PTYs are recreated; a Seter-aware launcher must reconnect or restore remote agents.
- **Host restart:** the Seter VM and Herdr server both need explicit reconciliation according to their configured lifecycle policies.

The initial integration should promise only normal Herdr detach/reattach persistence. Remote agent restoration after Herdr, VM, or host restart should remain explicitly unsupported until implemented and tested.

## Alternative: Herdr inside each VM

Running a Herdr server in each VM remains a valid alternative:

```sh
herdr --remote project-a-vm
```

Because Herdr, Pi, the socket, process tree, cwd, and session files are co-located inside the VM, this gives the most complete native integration and restoration semantics without exposing host control.

The drawback is architectural: each VM has a separate Herdr server and session. Herdr's current remote attach mode connects a local thin client to one remote server; it does not aggregate agents from several remote servers into one host sidebar. A true multi-server solution would require a federated dashboard or upstream Herdr support.

For Seter's desired unified host interface, one host Herdr server plus a restricted capability gateway is the preferred direction.

## Proposed implementation phases

### Phase 0: manual proof of concept

- Run Herdr on the host.
- Start a Seter VM explicitly.
- Create a manually labelled Herdr workspace.
- Run shell and Pi panes through strict SSH.
- Set `HERDR_AGENT=pi` on the host-visible Pi launcher.
- Verify screen-based status detection and terminal behavior.

This phase requires no Herdr socket exposure.

### Phase 1: host workspace binding

- Add a host-owned Seter-to-Herdr association.
- Create/focus the correct Herdr workspace from a Seter launcher or plugin.
- Add approved **new VM shell** and **new VM agent** operations.
- Ensure new panes cannot silently expose a host shell.
- Define pane-move, VM-disconnect, and workspace-close behavior.

### Phase 2: lifecycle gateway

- Implement a pane-scoped, protocol-compatible gateway.
- Pass Herdr integration environment into the guest.
- Install or package the Pi integration inside the guest.
- Permit only lifecycle and selected metadata reports.
- Strip guest session references initially.
- Test spoofing, cross-pane access, stale pane IDs, disconnects, and malformed protocol messages.

### Phase 3: workspace orchestration

- Add a workspace-scoped capability.
- Filter all list, read, wait, and event operations.
- Add semantic sibling-agent prompting and spawning.
- Translate spawn requests into fixed Seter VM launch operations.
- Ensure no request fields can select arbitrary host commands, paths, or environments.

### Phase 4: remote-aware restoration

- Persist remote session identity with the durable Seter workspace identity.
- Reconcile Herdr workspaces and Seter VMs after cold restart.
- Resume agents through the approved VM launcher.
- Test duplicate sessions, stale references, unavailable VMs, and partial restore failures.

## Security invariants

Any implementation should preserve these invariants:

1. The real host Herdr socket is never exposed to a project VM.
2. A VM can report lifecycle state only for panes assigned to that VM.
3. A VM cannot inspect or control another Seter workspace.
4. A VM cannot request an arbitrary host command, executable, cwd, environment, plugin, or socket method.
5. Every new pane in a VM-bound workspace either enters the bound VM or fails closed.
6. SSH failure must not leave an interactive host shell exposed in an agent-controlled pane.
7. Guest session paths are never executed or interpreted as host paths.
8. Durable authorization uses Seter workspace identity, not mutable labels or guessed Herdr runtime IDs.
9. VM and pane lifecycle operations remain explicit and auditable.
10. The gateway is treated as part of Seter's host security boundary and tested accordingly.

## Open questions

- Should the integration be primarily a Seter subcommand, a Herdr plugin, or a small service plus both frontends?
- What durable Herdr workspace identity can safely be reconciled with a Seter workspace after restart?
- Can Herdr create a pane with the VM launcher before any host shell becomes interactive, including normal UI splits?
- Should closing the final workspace client stop, suspend, or leave the VM running?
- What is the expected behavior when SSH drops but the VM-side agent is still running?
- Which Herdr read, prompt, wait, and event methods can be safely exposed after resource filtering?
- Should workspace-scoped agents be able to coordinate every agent in the VM, or only agents they created?
- Which transport best fits both NixOS and the planned nested macOS deployment?
- Should remote session restoration be implemented locally or proposed as a configurable launcher feature upstream in Herdr?
- How should multi-repo Seter workspaces choose initial cwd and display labels for individual panes?

## Current conclusion

The desired architecture is feasible without running Herdr inside every Seter VM. The current preferred direction is:

- one Herdr server on the host;
- one Herdr workspace bound to each Seter workspace VM;
- one strict SSH connection per pane;
- `HERDR_AGENT` hints as the initial detection mechanism;
- a pane- and workspace-scoped capability gateway for deeper integration;
- no raw host Herdr socket forwarding;
- remote-aware session restoration deferred until it can route through the workspace-to-VM binding safely.

This preserves Herdr's unified multi-project workflow while keeping project agents and code inside Seter's VM boundary.
