# Seter

<p align="center">
  <img src="assets/seter-logo.png" alt="Seter logo: a Norwegian summer farm with subtle circuit-board elements" width="280">
</p>

Seter runs development projects in isolated, Nix-managed micro-VMs. Shared host/guest workspace identity, runner identity verification, guest and host lifecycle behavior, persistent private Nix store overlays, a fail-closed workspace network boundary, exact-name guest DNS, transparent HTTP/HTTPS policy enforcement, allowlisted direct-TCP egress, approved host-daemon relays, declarative proxy trust, and destination-bound HTTP-header secret injection are implemented as an early vertical slice.

See [project-description.md](./project-description.md) for the intended architecture and threat model.

## Core concepts

A trusted workspace registry uses `seter.lib.mkWorkspaceDefinition` to produce a host policy projection and a sanitized guest identity module from one definition. A project imports that generated module alongside `seter.nixosModules.guest` and exports a NixOS microVM configuration; a NixOS host imports `seter.nixosModules.host` and registers the matching host projection.

```text
project flake                     NixOS host
     │                                │
     └─ VM installable ── seter update ──> last-built runner
                                               │
                                          seter up
                                               │
                                          running VM
```

- **Workspace:** one isolated development environment, usually associated with one project repository.
- **Installable:** the Nix reference identifying what to build, for example `github:owner/project#nixosConfigurations.guest.config.microvm.declaredRunner`.
- **Runner:** the immutable build result containing the launcher and references needed to boot that specific VM configuration.

`seter update <workspace>` builds the installable and retains its runner. `seter up <workspace>` starts that last-built runner without rebuilding, so configuration changes only take effect after an explicit update.

The lifecycle is explicit:

```console
seter update project        # builds unprivileged, then prompts for the install step
seter up project
seter status project
seter shell project
seter down project
```

`update` atomically installs the immutable runner under the workspace state directory, updates its current GC root under `/nix/var/nix/gcroots/per-project`, and retains a history root for every runner generation that may back the persistent guest Nix database. `up` never evaluates Nix. The VM runs as its dedicated `seter-*` system account with the registry's memory and CPU limits; runner-provided TAP and VirtioFS helpers are not executed.

## Shared workspace registry

Create the workspace once in trusted infra configuration:

```nix
project = seter.lib.mkWorkspaceDefinition {
  name = "project";
  runnerInstallable =
    "github:owner/project#nixosConfigurations.guest.config.microvm.declaredRunner";
  ip = "10.100.0.10";
  mac = "02:00:00:00:00:10";
  tap = "seter-project";
  allowedHTTPHosts = [ "api.example.com" ];
};

seter.host = {
  enable = true;
  workspaces.project = project.host;
};

# Export project.guestModule, then import it in the project configuration
# alongside seter.nixosModules.guest. A direct infra-flake import exposes the
# infra source; use a separate sanitized identity flake when that is private.
flake.nixosModules.projectIdentity = project.guestModule;

# Starting and stopping registered workspaces is an explicit host capability.
users.users.alice.extraGroups = [ "seter-operators" ];
```

The guest module fixes the workspace name, IPv4 and MAC addresses, TAP, gateway, prefix, DNS and proxy endpoints, SSH user, project-image basename, and private Nix-store image and capacity. Assertions also check the effective microVM interface, NixOS network wiring, proxy variables, persistent volumes, writable-store overlay, sandboxed guest builds, SSH access, placeholders, and proxy CA so lower-level overrides fail evaluation. The module embeds the non-secret identity in `/etc/seter/workspace.json` and in the runner at `share/seter/identity.json`. `seter update` compares that manifest with the root-owned host registry before installing a runner, and `seter up` rechecks the installed runner before each cold start, so ordinary stale identity fails with a direct error instead of producing a disconnected VM. The runner controls its manifest, so this is consistency checking rather than attestation; host-side network and privilege policy remains authoritative.

Every workspace on one host bridge must have a unique IPv4 address, MAC address, TAP interface, and hostname. Evaluation fails when entries conflict. Host-only egress policy and secret source paths are omitted from the generated guest module and runner closure, but a project importing the infra flake can still read that flake's tracked source. Use a separate sanitized identity source if those definitions are confidential. The low-level `lib.mkWorkspace` constructor remains available for compatibility but does not enable runner identity verification. See [Generated workspace identity](./docs/workspace-identity.md) for the complete contract and migration instructions.

## Host runtime plumbing

When `seter.host.enable` is set, the host creates the configured bridge at boot and assigns `seter.host.gateway` to it (`10.100.0.1` by default). Workspace TAP interfaces and VirtioFS daemons remain off while idle. Starting `seter-runtime-<workspace>.target` creates the registered TAP, attaches it to the bridge, and starts a host-owned `virtiofsd` that exposes only `/nix/store` read-only:

```console
sudo systemctl start seter-runtime-project.target
sudo systemctl stop seter-runtime-project.target
```

The VirtioFS socket is `/run/seter/<workspace>/virtiofs-ro-store.sock`. Each workspace receives a separate host system account and private state directory under `/var/lib/seter/workspaces`. The runtime units never execute helpers from a workspace runner as root.

Inside the guest, the read-only host store is the lower layer of an overlay mounted at `/nix/store`. **The current vertical slice exposes the entire host store read-only, including unrelated non-secret source and configuration artifacts; this is a known isolation gap, and the accepted design replaces it with a workspace-specific [closure-filtered Store View](./docs/store-visibility.md).** A dedicated ext4 image, `<workspace>-nix-store.img` by default, is mounted at `/nix` and retains both the overlay's upper/work directories and `/nix/var/nix`. Consequently `nix build`, `nix develop`, and nix-direnv can realize missing paths without writing to the host store, and their database registrations survive clean-root reboots. Seter roots every booted runner closure on both sides of the overlay for upgrades and rollbacks. Only those registered closures are guaranteed to deduplicate; unrelated paths merely present in the host store may be rebuilt privately. Guest store GC is disabled because stock Nix would scan the merged lower store and create persistent whiteouts; reclaiming space currently means replacing the bounded private image. Guest builds remain sandboxed and their fetches remain inside the workspace network boundary. Configure the initial capacity with `nixStoreSizeMiB` in `mkWorkspaceDefinition`; existing images are not resized automatically. See [Private writable Nix stores](./docs/nix-store.md).

These units provide VM plumbing only. They do not start the VM. Separate host-owned DNS, proxy, direct-TCP resolver, and nftables services keep every workspace fail-closed while enabling only declared application egress.

## Network isolation

Every workspace TAP is an isolated bridge port. Host-owned nftables rules bind each TAP to its registered IPv4 and MAC addresses, reject forged ARP and IPv4 identities, block IPv6 until it has an explicit policy, and deny workspace-initiated traffic to the host, other workspaces, and routed networks except for explicitly selected gateway services. Host-initiated connections such as `seter shell` remain available.

Seter requires and enables NixOS's native `networking.nftables` backend so its tables participate in the host's complete atomic firewall transaction. **This switches the host firewall backend from legacy iptables and may require changes for Docker, libvirt, or other software that manages iptables rules. Review those services before enabling the host module.**

The nftables policy is installed before any TAP can start. A policy-loading failure prevents the workspace runtime from starting, and stopping nftables stops active workspace TAPs before removing their rules. The boundary does not rely on forwarding being disabled or on unrelated firewall rules rejecting traffic.

A separate unprivileged policy resolver runs on demand for each active workspace behind the bridge gateway. Workspaces may query the gateway over TCP or UDP, but only exact names derived from that workspace's configured HTTP, passthrough, and direct-TCP destinations are accepted. Names are compared case-insensitively with an optional final dot; a configured `api.example.com` does not authorize `child.api.example.com`. nftables redirects each registered source address to its own listener, and the listener independently verifies the registered source address, so one workspace's destinations do not broaden another's DNS policy.

Only `A` requests cross the policy boundary. The resolver constructs a fresh canonical query before sending it to a shared loopback-only dnsmasq cache, preventing guest-controlled case, message IDs, extra questions, additional sections, and EDNS options from reaching an upstream resolver. Exact `AAAA` requests receive a local empty response because IPv6 is out of scope. Other classes and record types, malformed packets, multi-question packets, and non-exact names are refused. Direct DNS to outside resolvers remains blocked over both UDP and TCP.

By default, allow and deny decisions are written as single-line JSON records prefixed with `seter-dns-audit` in each workspace's `seter-dns-<workspace>.service` journal. Set `seter.host.dns.logQueries = false` to disable them. Per-workspace rate, burst, concurrency, query-size, and upstream-timeout bounds limit resource abuse. Set `seter.host.dns.upstreamServers` to explicit IPv4 recursive resolvers, or leave it empty to use the host's existing `/etc/resolv.conf`; these are contacted only by the loopback caching backend. Host applications resolve registered workspace hostnames through generated `/etc/hosts` entries; Seter does not replace the host resolver.

DNS is the only generally permitted UDP protocol. UDP/443 remains blocked so HTTP/3 or QUIC cannot bypass the TCP HTTP policy, and arbitrary UDP remains unavailable unless a future protocol-specific policy supports it. DNS-over-TLS is blocked unless its endpoint is deliberately authorized as direct TCP. ICMP and other IP protocol egress remain default-denied. IPv6 is deliberately out of scope and blocked at the bridge boundary. See [DNS policy](./docs/dns-policy.md) for the wire-level policy and resource controls.

A hardened, unprivileged mitmproxy service transparently intercepts registered workspace TCP traffic to ports 80 and 443. The source IP selects the workspace policy, and only exact names in that workspace's `allowedHTTPHosts` are accepted. The proxy requires HTTPS SNI and the HTTP host to agree, then resolves and pins the reviewed hostname instead of trusting the packet's original destination or a later DNS answer. Only publicly routed IPv4 answers are accepted, preventing an allowed name from rebinding the host-side proxy onto loopback, link-local, Seter, or private LAN services. Denials return HTTP 403 with a policy reason; raw TCP and HTTP CONNECT tunnels through the interception ports are disabled.

Names in `passthroughHosts` use the same transparent port but bypass TLS interception. The proxy authorizes the exact ClientHello SNI, resolves that reviewed name itself instead of trusting the packet destination, and relays the encrypted connection unchanged. This supports certificate-pinned clients and keeps bulk HTTPS payloads out of TLS decryption and HTTP parsing, although encrypted bytes still traverse mitmproxy's userspace TCP relay. A name cannot be configured for both interception and passthrough, and passthrough does not permit cleartext HTTP.

Allow and deny decisions are written as single-line JSON records prefixed with `seter-audit` in the `seter-proxy.service` journal. Allowed passthrough connections are logged with their SNI, but their encrypted requests remain opaque. Set `seter.host.proxy.logRequests = false` to disable this audit logging. Intercepted HTTP logs include the URL path, which may contain sensitive query parameters. `seter.host.proxy.upstreamCaFile` may provide a custom PEM trust bundle for intercepted upstream HTTPS verification. The proxy uses fixed UID 60534 for nftables output isolation; override `seter.host.proxy.uid` if that UID is already allocated locally.

Direct non-HTTP TCP destinations declared with `allowedTCP` are resolved by a host-owned service into a separate nftables address-and-port set for each workspace. Set replacement is atomic, active sets are immediately repopulated after an nftables reload, and every packet remains conditional on the current set so removing an address also revokes established connections. Routed connections are narrowly forwarded and masqueraded through NixOS's enabled forwarding firewall. Seter defaults `networking.firewall.filterForward` on and rejects direct-TCP policy when either the firewall or forward filtering is disabled, so enabling kernel forwarding cannot expose unrelated host interfaces. DNS-derived destinations must be publicly routed unicast IPv4 addresses, preventing an allowed name from rebinding onto loopback, link-local, multicast, private LAN, or workspace services. To deliberately authorize a non-public destination, configure its literal IPv4 address rather than a hostname. Ports 80 and 443 cannot be declared as direct TCP because they always pass through the HTTP policy proxy. As with any layer-3 allowlist, destinations sharing an IP address and port are indistinguishable.

Named host daemons can be exposed through fixed TCP relays on the Seter gateway. A relay can target only IPv4 loopback, binds only the bridge gateway, runs as a hardened dynamic user, starts on demand with an authorized workspace's TAP, and stops after becoming idle once no authorized TAP needs it. The earlier Seter nftables chain admits only the exact registered workspace source address, gateway address, protocol, and listener port; defining a relay does not authorize any workspace by itself. Listener ports must be unique and cannot collide with proxy or generated DNS ports.

```nix
seter.host.gatewayServices.adb = {
  listenPort = 5037;
  targetAddress = "127.0.0.1"; # the only permitted target address
  targetPort = 5037;
};

seter.host.workspaces.android.hostServices = [ "adb" ];
```

Keep the real daemon loopback-only; never make ADB listen on `0.0.0.0`. In the guest, set `ADB_SERVER_SOCKET=tcp:10.100.0.1:5037` (using that guest's configured gateway). Authorization grants the daemon's full protocol capability: workspaces sharing one ADB server can see and control the same device inventory. These relays are transport policy, not authentication; exposing SSH, the Nix daemon, Docker, or another privileged control plane still requires a separately restricted application-level service. Only TCP loopback targets are supported initially.

mitmproxy generates its site interception CA once in persistent `/var/lib/seter-proxy` state. That directory and both private-key formats remain readable only by the unprivileged proxy account; Seter publishes only the public certificate under `/var/lib/seter-proxy-public/seter-proxy-ca-cert.pem`. Export and review it, commit only that public certificate to the trusted workspace or infra configuration, and install it declaratively in each guest:

```console
seter proxy-ca > seter-proxy-ca-cert.pem
# Compare the SHA-256 fingerprint printed on stderr through a trusted channel.
```

```nix
seter.guest.proxyCaCertificate =
  builtins.readFile ./seter-proxy-ca-cert.pem;
```

Network-enabled guests default `HTTP_PROXY`, `HTTPS_PROXY`, and their lower-case equivalents to the host's explicit endpoint at `http://<gateway>:18081`; `NO_PROXY` covers loopback and the guest's own static address. If `seter.host.proxy.explicitPort` is changed, set `seter.guest.proxy` to the matching URL. These variables are only a compatibility convenience: transparent redirection still enforces policy for applications that ignore them. Explicit HTTPS CONNECT is restricted to exact reviewed hosts on port 443 and is rechecked at the TLS layer and, for intercepted traffic, the HTTP layer.

`security.pki.certificates` makes the CA available through the NixOS system trust bundle, which covers tools using the system OpenSSL trust configuration. Applications with private trust stores—commonly browsers using private NSS profiles, Java applications with bundled JKS files, and language tools that replace rather than inherit system roots—must import the same public certificate into that store. Certificate-pinned software should use `passthroughHosts` instead. Never copy `/var/lib/seter-proxy/mitmproxy-ca.pem`: it contains the private signing key and must not enter a guest, repository, or the Nix store.

Back up `/var/lib/seter-proxy` as site security state. Losing it generates a new CA on the next proxy start and requires re-exporting the certificate and rebuilding every guest; compromise requires rotating the CA and rebuilding every guest. HTTPS fails closed while a guest trusts the wrong generation.

Configured secret source files are staged for the unprivileged proxy with systemd credentials: PID 1 reads the consumer-managed path and exposes a private, read-only snapshot under `$CREDENTIALS_DIRECTORY`. Secret values do not enter the Nix store, process arguments, or environment variables. Runtime values must be 8 bytes through 16 KiB of ASCII without control characters; one final LF or CRLF from a text secret file is removed before validation.

For an intercepted HTTPS request, the addon replaces an exact configured placeholder only in configured header values and only when the request host matches that secret's binding. Cleartext HTTP and an otherwise-allowed but unbound host return 403 instead of forwarding a recognized placeholder. Exact credential values reflected in response headers or decoded response bodies are changed back to placeholders before reaching the workspace. Secret names, but never values or header contents, appear in audit records.

```nix
seter.host.workspaces.project = {
  egress.httpHosts = [ "api.github.com" ];
  secrets.githubToken = {
    placeholder = "seter-placeholder-github-0123456789abcdef";
    sourceFile = "/run/secrets/github-token";
    hosts = [ "api.github.com" ];
    headers = [ "authorization" ];
  };
};
```

For a shared workspace definition, map guest environment variables to secret names without repeating the placeholder:

```nix
project = seter.lib.mkWorkspaceDefinition {
  # identity and runner fields omitted here
  secrets.githubToken = {
    placeholder = "seter-placeholder-github-0123456789abcdef";
    sourceFile = "/run/secrets/github-token";
    hosts = [ "api.github.com" ];
    headers = [ "authorization" ];
  };
  secretVariables = {
    GITHUB_TOKEN = "githubToken";
    GH_TOKEN = "githubToken";
  };
};
```

The generated guest module exports both matching non-secret placeholders to login sessions. An `Authorization` header containing that exact value is rewritten at the network edge. Placeholder variables are intentionally baked into the guest and the Nix store; real values must never be assigned to `secretPlaceholders`. Systemd services do not inherit login-session variables and must be given the same non-secret placeholder explicitly. Query strings and request bodies are deliberately not rewritten.

Response redaction prevents straightforward accidental reflection, but it is not a data-loss-prevention boundary. An authorized service can transform, split, encode, or deliberately disclose a credential or credential-derived information in ways a generic proxy cannot recognize. The guest is therefore not *provisioned* the credential, but the bound service remains inside the credential's trust boundary. Use a separate, least-privilege credential for every workspace and grant only the API capabilities that workspace may exercise.

`LoadCredential` snapshots values when `seter-proxy.service` starts, so the secret manager must restart that service after rotating a source file. With sops-nix, for example:

```nix
sops.secrets.github-token.restartUnits = [ "seter-proxy.service" ];
```

Other secret managers must arrange the equivalent restart. See [Destination-bound secret injection](./docs/secret-injection.md) for the full policy contract, threat boundary, rotation procedure, and troubleshooting guidance.

## VM lifecycle

The host also declares an on-demand `seter-vm-<workspace>.service`. The CLI controls that fixed unit rather than executing a VMM itself. Starting it brings up `seter-runtime-<workspace>.target`, snapshots the installed runner as `booted`, and launches `microvm-run` from the workspace's private state directory. Stopping it uses the matching `booted/bin/microvm-shutdown`, with a systemd timeout and forced termination as a fallback, then removes the TAP and VirtioFS socket. The project volume is retained.

`seter status [workspace]` reports `not-built`, `stopped`, `starting`, `running`, `stopping`, or `failed`. A stopped single-workspace status exits with code 3 for scripting.

Lifecycle control is privileged through systemd. Members of `seter.host.operatorGroup` (`seter-operators` by default) may use `seter up` and `seter down` without a sudo password. The CLI elevates only an exact hidden start or stop operation for the named, registered workspace; generated sudoers rules do not grant arbitrary `seter`, `systemctl`, or root command execution. The privileged operation discards environment overrides, reloads the root-owned registry, and constructs the fixed unit name itself.

`seter update` still performs the potentially untrusted Nix build as the invoking user, then separately elevates its narrowly scoped install operation to update root-owned state and GC roots. Project runner code always executes as the workspace account, never as root. See [Lifecycle authorization](./docs/lifecycle-authorization.md) for the trust boundary and implementation rules.

## SSH host-key enrollment

SSH never silently trusts a network-provided key. After the first boot has generated the guest identity, stop the workspace and read its public key directly from the host-owned ext4 project image:

```console
seter up project
seter down project
seter ssh-host-key project
```

Review the printed fingerprint, copy the public key into the workspace registry's `knownHostKey`, rebuild the host configuration, and then use `seter shell project`. Shell connections use the registered IP and user, strict host-key checking, and no SSH agent or X11 forwarding. The guest flake must separately include the developer's public login key in `seter.guest.ssh.authorizedKeys`.

## Development

```console
nix develop
cargo test
cargo run -- --help
nix flake check
```

On `x86_64-linux`, `nix flake check` includes a nested-KVM lifecycle test that boots the minimal guest through the host module and CLI, connects over SSH, builds a derivation into the private store, and verifies project-volume, Nix-store, and Nix-database persistence across a restart. It requires writable `/dev/kvm` and nested virtualization support.

## Flake outputs

- `packages.<system>.seter`: Rust CLI
- `apps.<system>.default`: Seter CLI application
- `nixosModules.host`: host-side Seter module
- `nixosModules.guest`: project guest module
- `lib.mkWorkspaceDefinition`: shared host/guest workspace constructor with runner identity verification
- `lib.mkWorkspace`: low-level compatibility host-registry constructor
- `nixosConfigurations.minimal`: buildable reference microVM
- `apps.x86_64-linux.test-minimal`: KVM-backed minimal guest verification

## Status

The guest boundary has a tested minimal vertical slice. A shared workspace definition generates matching host and sanitized guest projections, embeds a versioned identity in the guest and runner, and prevents installation or cold start of mismatched runners. The host exposes a validated workspace registry, lifecycle-owned bridge/TAP/VirtioFS plumbing, fixed per-workspace VM services, fail-closed TAP identity and network isolation, exact-name canonical guest DNS, transparent HTTP/HTTPS host enforcement with SNI passthrough, allowlisted direct TCP egress, per-workspace host-daemon gateway relays, persistent private guest Nix stores above the shared read-only host store, persistent proxy CA enrollment and declarative guest trust, destination-bound HTTPS-header secret injection from private runtime credentials, and CLI operations for runner updates, start, status, shutdown, strict SSH shell access, and offline SSH host-key enrollment.
