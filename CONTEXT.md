# Seter

Seter limits the authority of development workloads by placing each workspace behind a host-controlled isolation and policy boundary.

## Language

**Workspace**:
An isolated development environment with one working tree, its persistent state, and granted capabilities. It is the unit whose blast radius Seter limits.
_Avoid_: Project VM, sandbox

**macOS Client**:
The physical Mac from which an operator accesses Seter. It is outside the Seter Host's workspace isolation and policy boundary.
_Avoid_: macOS host, Mac host

**Client Exchange Directory**:
One explicitly selected directory belonging to the macOS Client that the Seter Host may read and write for deliberate file exchange. It is never directly available to a Workspace.
_Avoid_: Shared home, host home mount

**Seter Host**:
The trusted operating environment that owns the Workspace Registry, enforces policy, and runs Workspace Runners. On macOS deployments, it is distinct from the macOS Client.
_Avoid_: Outer VM, Lima VM

**Workspace Registry**:
The trusted catalog of workspace identities, approved repository sources, resource limits, and granted capabilities.
_Avoid_: Project list, VM registry

**Workspace Bootstrap**:
The creation of a workspace's initial working tree and persistent development state from its approved repository source.
_Avoid_: Setup, provisioning, initialization

**Runner**:
The immutable host-deployed artifact that boots a workspace with its trusted Guest Profile and registered identity.
_Avoid_: VM image, launcher

**Store View**:
The workspace-specific read-only set of host Nix store paths reachable from its deployed and retained Runner closures.
_Avoid_: Host store, shared store

**Workspace SSH Identity**:
The server identity used to verify that an SSH connection terminates at the intended workspace.
_Avoid_: User key, login key

**Repository Authority**:
A workspace's permission to read from and write to its single approved repository without receiving the repository credential itself.
_Avoid_: Git access, repository secret

**Guest Profile**:
A reusable, trusted definition of the operating-system capabilities available inside a workspace.
_Avoid_: VM template, base image

**Project Guest Configuration**:
An optional repository-owned definition of workload-specific guest requirements for a workspace that cannot use a generic Guest Profile alone.
_Avoid_: Project flake, custom VM

**Policy Observation**:
An allowed or denied attempt by a workspace to use a network destination or host capability.
_Avoid_: Firewall log, request log

**Policy Grant**:
A reviewed addition to a workspace's authority, made in response to an understood requirement rather than merely observed traffic.
_Avoid_: Opening a port, whitelisting

**Policy File**:
A consumer-owned, declarative catalog of Policy Grants that is reviewed and deployed as part of trusted host configuration.
_Avoid_: Firewall config, allowlist file

**Host Pattern**:
An exact hostname or a leading wildcard that matches exactly one subordinate DNS label. A wildcard excludes the named apex and cannot bind credential authority.
_Avoid_: Domain, glob, recursive wildcard

**Workspace Retirement**:
The removal of a workspace from active use while retaining its Project Volume unless a separate destructive action explicitly removes it.
_Avoid_: Garbage collection, deletion

**Project Volume**:
The persistent workspace storage containing its approved repository working tree. Reset and garbage collection never remove it.
_Avoid_: Workspace state, home disk

**Home Volume**:
The resettable persistent workspace storage containing user configuration, tool state, approvals, history, and non-Nix caches.
_Avoid_: Host home, project disk

**Workspace Reset**:
The explicit replacement of selected reproducible workspace state while retaining the Project Volume, Workspace SSH Identity, and Policy Grants.
_Avoid_: Cleanup, garbage collection, destruction
