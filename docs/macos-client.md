# Native macOS client

The same Rust `seter` CLI runs on Linux and Apple Silicon macOS. On Linux,
Workspace commands execute locally. On macOS, the client connects to the
trusted Linux Seter Host through Lima's generated SSH configuration and invokes
its installed CLI. Policy enforcement and Workspace execution remain on Linux.

The native client has Linux integration coverage using real OpenSSH, TCP, and
Unix-socket forwarding. Darwin packaging evaluates on Linux. Native Mac
execution, Lima integration, and Docker clients still require physical
acceptance; see [validation status](./macos-validation.md).

## Install and select the Host

Install from a Seter checkout:

```sh
nix profile install path:.#seter
```

After [bootstrap](./macos-deployment.md), select the retained Lima instance and
trusted consumer configuration:

```sh
seter host configure --lima seter \
  --flake "$HOME/seter-exchange/consumer" \
  --configuration seter-host \
  --exchange-directory "$HOME/seter-exchange"
```

Configuration selects an existing instance. It does not create, replace, or
delete its disk. The default connection targets the instance `seter`.

The client reads `$XDG_CONFIG_HOME/seter/client.toml`, falling back to
`$HOME/.config/seter/client.toml`. Use `--client-config <file>` or
`SETER_CLIENT_CONFIG` to select another file. Explicit configuration selection
also selects the Lima transport on Linux, which is useful for integration
testing. Without that selection, Linux commands retain local execution.

The configuration is private TOML. Paths and settings below are synthetic:

```toml
version = 1
instance = "seter"
flake = "/absolute/path/to/consumer"
configuration = "seter-host"
exchange_directory = "/absolute/path/to/exchange"
exchange_mount = "/workspace/seter-exchange"
host_seter = "/run/current-system/sw/bin/seter"
forward_agent = true
docker_socket = "/var/run/docker.sock"
```

Optional paths can be omitted. `host configure` accepts the corresponding
flags, including `--forward-agent false`. Updating configuration requires
managed connections to be disconnected first.

## Host and Workspace commands

```sh
seter host start
seter host status
seter host shell
seter host run -- uname -r
seter host run --cwd /project/example -- cargo test
seter host deploy --max-jobs 2 --cores 2
seter host stop
```

Host shell and run execute as the Lima SSH user directly on the trusted Host.
They do not create a Workspace isolation boundary. On native Linux, Host shell
and run execute as the current user on that machine. Host start and stop apply
only to managed Lima instances and never power off a native Linux machine.

On macOS, shell, run, deployment, and connection creation start the retained
Host when needed. Status commands do not start it. Deployment evaluates the
trusted consumer flake on the Client and uses the Linux Host for both builds
and activation. Override its configured source with `--flake` and
`--configuration`. Deployment requires the operator's existing sudo authority;
Seter adds no deployment privilege.

Workspace commands retain their existing syntax:

```sh
seter init example
seter shell example
seter run example -- cargo test
seter status example
seter down example
```

Commands retain argument boundaries and exit codes. Interactive shell entry
uses a TTY when the Client's input is a terminal. The attended connection may
forward the Client agent to the trusted Host, according to `forward_agent`;
Host-to-Workspace SSH still disables agent and X11 forwarding. Long-lived
connection masters do not forward the agent.

Host stop first gracefully stops every registered Workspace, then detaches
managed connections and stops Lima. It retains the Host disk and Workspace
volumes. Instance deletion remains an explicit Lima operation.

## Docker

Enable Docker in trusted consumer configuration and authorize the Host SSH
user to access its Unix socket. The client does not install or enable the
daemon. Docker access grants control over the Host and must not be exposed to
an untrusted Workspace.

```sh
eval "$(seter host docker env)"
docker ps

seter host docker context --use
docker ps
seter host docker status
seter host docker disconnect
```

The client verifies the Host Docker API, creates an SSH Unix-socket forward
to a private Client socket, and verifies that forwarded API. It needs no
preconfigured Lima socket forwarding. `docker context` creates or updates
`seter-<instance>`; `--name` selects another context. Only `--use` changes the
Docker client's selected context. The Docker CLI must be installed on the
Client for context commands.

After disconnection or Host stop, rerun env or context to reconnect. Context
definitions remain in Docker's own configuration.

## Development-service forwarding

```sh
seter host forward start 3000
seter host forward start 3000 --local-port 3001 --open
seter host forward list
seter host forward stop 3001
```

Each connection forwards Client `127.0.0.1:<local-port>` to Host
`127.0.0.1:<port>`. Local ports must be at least 1024. `--open` opens an HTTP
URL in the Client's browser. Forward creation confirms listener setup, while
the application may start later. Port collisions fail instead of silently
using another listener. A repeated identical request reuses its connection.

For Docker applications, publish the application port on Host loopback and
forward that port. For nested Workspace services, use the existing
[Workspace tunnel procedure](./macos-workflow.md#open-a-loopback-only-workspace-service-tunnel)
with trusted development-port grants.

Managed connection state and socket directories are private to the operator.
The client manages only its own SSH masters. Connections can become stale
after Client sleep, Host restart, or external Lima operations; rerun the
relevant env, context, or forward command to reconnect.
