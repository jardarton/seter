# macOS manual operator workflow

## Scope

This is the accepted manual operator workflow for the initial macOS
integration. Seter still runs inside the trusted `aarch64-linux` Seter Host;
there is no Darwin Seter CLI and no automatic Lima or tunnel management.

Complete [bootstrap and deployment](./macos-deployment.md) first. The
commands below use the default Lima instance `seter`, Workspace `example`, and
consumer configuration in the Client Exchange Directory. Substitute the names
and paths owned by the consumer.

These instance names, SSH aliases, accounts, ports, and paths are examples or
product defaults, not identifiers from a test machine. Keep actual consumer
configuration, keys, and command output outside the Seter repository.

## Start and enter the Seter Host

Start the retained instance explicitly:

```sh
limactl start seter
limactl shell seter
```

Run a single command without an interactive Host shell with:

```sh
limactl shell seter -- seter status
limactl shell seter -- bash -lc 'seter run example -- cargo test'
```

`limactl shell` propagates the remote command's exit status. It does not grant
an ambient SSH agent to the Seter Host because `lima/seter.yaml` deliberately
sets `forwardAgent: false`.

For an attended development session that needs the macOS operator agent, use a
fresh explicit SSH connection through Lima's generated configuration:

```sh
instance_dir=$(limactl list seter --format '{{.Dir}}')
ssh -A \
  -o ForwardAgent=yes \
  -o ControlMaster=no \
  -o ControlPath=none \
  -F "$instance_dir/ssh.config" \
  lima-seter
```

Disabling connection sharing is required: Lima starts an ordinary
ControlMaster without agent forwarding, and reusing it would silently omit the
agent from this connection. Confirm the intended identity with `ssh-add -l` in
the Seter Host. The Host is trusted and may use the forwarded agent for the
duration of this connection; do not use this path for unattended work.

From that Host shell, normal operator commands are:

```sh
seter init example
seter shell example
seter run example -- cargo test
```

`init` safely bootstraps all registered repositories. For a multi-repository
Workspace, select a checkout with `shell` / `run --repo <key>` or configure
`defaultRepository`; `shell --root` opens `/project`. Review any `.envrc` and
explicitly run `direnv allow` inside the Workspace before `run` can load it.

Seter allocates a Workspace TTY for `shell`, propagates terminal signals and
the nested shell's exit status, and uses strict Workspace SSH Identity
verification. Both `shell` and `run` force `ForwardAgent=no` on the
Host-to-Workspace hop. The Workspace must not contain `SSH_AUTH_SOCK` and never
receives the operator's private key.

## Review and deploy policy through the exchange directory

The Client Exchange Directory is mounted read-write only in the Seter Host at
`/workspace/seter-exchange`; it is never mounted into a Workspace. Review an
observed denial against the consumer-owned Policy File:

```sh
seter audit example --since 30m
seter policy review example \
  --file /workspace/seter-exchange/consumer/policy.toml
seter policy status example \
  --file /workspace/seter-exchange/consumer/policy.toml
```

Inspect the resulting diff on macOS. A review changes desired authority only;
`policy status` reports deployment pending until trusted configuration is
redeployed:

```sh
git -C "$HOME/seter-exchange/consumer" diff -- policy.toml
nix run path:.#macos-host -- \
  deploy "$HOME/seter-exchange/consumer" seter-host
```

Reconnect and rerun `seter policy status`; desired and active policy must
agree. Deployment keeps the exchange directory mounted. The `limaHost` module
re-establishes its single cidata-declared virtiofs mount after NixOS activation
because the switch otherwise removes Lima's boot-generated mount unit.

## Open a loopback-only Workspace service tunnel

First obtain the registered Workspace address:

```sh
workspace_ip=$(limactl shell seter -- seter ip example | tr -d '\r')
instance_dir=$(limactl list seter --format '{{.Dir}}')
```

If a development service listens on Workspace port 3000 and the trusted Guest
Profile permits that inbound port, expose it only on macOS loopback:

```sh
ssh -N \
  -o ExitOnForwardFailure=yes \
  -o ControlMaster=no \
  -o ControlPath=none \
  -L "127.0.0.1:3000:${workspace_ip}:3000" \
  -F "$instance_dir/ssh.config" \
  lima-seter
```

Open `http://127.0.0.1:3000` while that foreground SSH process remains
running, and press Ctrl-C to close the tunnel. The explicit `127.0.0.1` bind is
mandatory. Do not add `-g` or bind `0.0.0.0`. A tunnel does not bypass the
Workspace firewall: the service port must already be part of the trusted Guest
Profile. Direct routing, subnet routing, Tailscale, and automatic tunnel
management remain out of scope.

## Stop safely

Stop Workspaces before stopping the retained Seter Host:

```sh
limactl shell seter -- seter down example
limactl stop seter
```

`limactl start` retains the disk. **Never run `limactl delete seter` unless the
intent is to destroy the Seter Host and every Workspace volume.** This
milestone does not provide backup or recovery from deletion or disk
corruption.
