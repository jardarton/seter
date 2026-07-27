# Policy observation and review

**Status:** accepted product design; the unified audit, review, Policy File, and desired-versus-active commands are not yet implemented. Current DNS and proxy decisions are available in service journals.

Seter's default-deny boundary is usable only when operators can understand failed traffic and grant narrowly reviewed authority without firewall archaeology. Observed traffic is evidence, never authorization: workspace code can produce Policy Observations, but only an explicit host-operator action can create a Policy Grant.

## Policy File

Policy Grants live in a dedicated TOML file owned by the consumer's trusted infra repository:

```toml
version = 1

[workspaces.example.egress]
http-hosts = ["api.github.com", "cache.nixos.org"]
passthrough-hosts = ["registry-1.docker.io"]

[[workspaces.example.egress.tcp]]
host = "example.net"
port = 2222
```

The consumer's Nix configuration imports this file and merges its grants into the Workspace Registry. Personal workspace names, destinations, file locations, and deployment commands remain in private consumer configuration; the public Seter repository defines only the schema and integration contract.

A dedicated file is intentional. Seter can safely parse, validate, preserve, and atomically edit TOML, but cannot reliably rewrite arbitrary Nix expressions. Policy changes remain reviewable version-controlled data rather than mutable runtime exceptions.

The Policy File contains network and host-capability grants only. It must not contain real credential values. Credential bindings and source paths remain separate trusted configuration and are never inferred from traffic.

## Observing policy decisions

`seter audit <workspace>` presents normalized records from only that workspace's DNS, proxy, passthrough, and direct-TCP policy boundary:

```console
seter audit example --since 30m
```

The default view groups repeated observations by decision, protocol, and exact destination. Request paths are hidden by default because they may contain sensitive query parameters; an explicit option may reveal them when diagnosis requires it.

Operators must not need broad access to unrelated host journals. Host integration should expose only the selected workspace's policy records through a narrow privileged helper or equivalent workspace-scoped interface.

Not every observation supports a safe proposal. An intercepted HTTP denial identifies an HTTP host candidate. A DNS query alone does not reveal whether the intended protocol is intercepted HTTP, TLS passthrough, or direct TCP, and blocked direct TCP may require additional host instrumentation to identify reliably. Seter asks the operator instead of guessing.

## Reviewing and proposing grants

The operator supplies the private Policy File explicitly or through private consumer configuration:

```console
seter policy review example --file /path/to/seter-policy.toml
```

The review groups observations, offers only grants supported by available evidence, and provides details on demand. The operator may approve, skip, or classify ambiguous traffic. A guest cannot invoke approval through the policy boundary.

Before writing, Seter displays the exact proposed diff and validates the complete file. Validation includes workspace existence, destination syntax, duplicate entries, HTTP/passthrough overlap, prohibited direct-TCP ports, and every other host policy invariant. Writes use locking, a temporary file, and atomic replacement so concurrent or interrupted review cannot corrupt policy.

Review never creates credential bindings, invokes arbitrary deployment commands, rebuilds the host, or applies temporary runtime exceptions.

## Host Patterns

A Policy Grant may name an exact host or use one leading wildcard. `*.example.com` matches `api.example.com`, but does not match the apex `example.com` or a deeper name such as `deep.api.example.com`.

Wildcard patterns are explicit operator choices. Seter never generalizes observed exact hosts into a wildcard proposal. It rejects wildcards at public-suffix and shared-hosting boundaries, rejects wildcard syntax anywhere except the complete leading label, and displays the expanded authority prominently during review. Intercepted-HTTP and passthrough patterns must not overlap.

Credential bindings remain exact-host and, where applicable, exact-repository-path grants. A wildcard can authorize intercepted HTTP or TLS passthrough egress but can never authorize Seter to inject a credential. Direct-TCP grants remain exact-host only; wildcard direct TCP would require dynamic DNS-driven firewall authority and is outside the initial contract.

## Deploying and reconciling

After review, the operator inspects the version-control diff and deploys through the consumer's normal NixOS workflow. A desired-versus-active command compares the Policy File with a non-secret effective-policy projection from the running host:

```console
seter policy status example --file /path/to/seter-policy.toml
```

It reports pending additions, pending revocations, or agreement. The effective projection contains grants but excludes secret values and secret source paths.

## Revocation

Review must make existing grants as easy to inspect and remove as denied destinations are to add. Removing a grant edits the same Policy File, follows the same diff and deployment process, and becomes effective only after trusted host deployment. Seter does not silently retain a runtime overlay.

## Security invariants

1. Policy Observations never become Policy Grants automatically.
2. Only explicit host-operator review changes the Policy File.
3. Guest code cannot approve, deploy, or create a temporary exception.
4. Credential authority is never inferred or granted through network review.
5. Desired and active policy remain distinguishable until host deployment.
6. Personal policy and infra locations remain outside the public Seter repository.
