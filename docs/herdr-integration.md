# Herdr integration

Herdr integration and remote agent restoration are
[explicitly deferred](../ROADMAP.md#explicitly-deferred). Seter currently has
no Herdr workspace bindings, control gateway, or remote session restoration.
Use `seter shell` and `seter run` manually from terminal panes for now.

Revisit integration when the core workspace workflow is established and there
is a concrete need for a unified agent dashboard. Any future design must:

- keep development workloads inside their registered Seter workspace and
  create panes through the trusted Seter SSH path;
- retain the host control socket on the Host, expose only narrowly authorized
  capabilities, and filter operations and results to the caller's workspace;
- bind authorization to trusted workspace identity rather than mutable labels
  or caller-supplied pane IDs;
- restore guest sessions inside the same workspace, with no fallback to host
  command execution when an SSH connection exits.

The earlier exploratory proposal remains available in Git history. Transport,
API methods, pane binding, and restoration behavior need a fresh design and
security review before implementation.
