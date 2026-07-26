# Destination-bound secret injection

Seter lets a guest use selected HTTP credentials without placing their real values in the guest, its environment, its filesystem, or the Nix store. The guest receives a public placeholder. The host proxy replaces that placeholder only in configured request headers sent over intercepted HTTPS to an exact configured destination.

This mechanism limits where a credential can be transmitted. It does not prevent compromised guest code from exercising the credential against its authorized service.

## Data flow

1. A host secret manager writes the real value to a runtime path such as `/run/secrets/github-token`.
2. When `seter-proxy.service` starts, systemd `LoadCredential=` snapshots that file into the service's private credential directory.
3. The Nix-rendered proxy policy identifies the systemd credential by name. It contains the public placeholder and destination/header bindings, but not the source path or real value.
4. The guest application reads the placeholder and sends it in a configured HTTP header.
5. After workspace, HTTPS SNI, HTTP authority, destination, and upstream address checks pass, the proxy replaces the exact placeholder in memory.
6. mitmproxy verifies the upstream TLS certificate before sending the rewritten HTTP request.
7. Exact credential values found in decoded response bodies or non-framing response headers are changed back to placeholders before the response reaches the guest.

The source path is present in the host's systemd unit configuration because PID 1 must load it. The secret value is not present in Nix derivations, unit files, command arguments, or environment variables.

## Configuration

Configure the host-side binding in the trusted workspace registry:

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

Header names are case-insensitive. Replacement applies to exact placeholder substrings, so both of these work:

```http
Authorization: seter-placeholder-github-0123456789abcdef
Authorization: Bearer seter-placeholder-github-0123456789abcdef
```

Export the same public value in the guest:

```nix
seter.guest.secretPlaceholders.GITHUB_TOKEN =
  "seter-placeholder-github-0123456789abcdef";
```

`secretPlaceholders` configures login-session variables. NixOS systemd services do not inherit them; pass the same public placeholder explicitly in the service's environment when needed. Placeholders are intentionally stored in the guest configuration and Nix store and must never be real credentials.

Keep shared host and guest placeholder declarations in one trusted Nix value where possible. A placeholder that matches no eligible host-side binding is forwarded unchanged and authenticates with a useless public value. A cross-wired placeholder that matches another eligible binding injects that binding's credential, so shared declarations also prevent accidentally selecting the wrong credential.

## Runtime credential format

A secret source must produce an ASCII value between 8 bytes and 16 KiB after removing at most one final LF or CRLF. Other control characters are rejected. These restrictions prevent a credential from injecting additional HTTP headers.

The source file may be supplied by sops-nix, agenix, or another host secret manager. Seter consumes only its runtime path and does not require a particular manager.

`LoadCredential=` is a start-time snapshot. Restart the proxy after rotation. For sops-nix:

```nix
sops.secrets.github-token.restartUnits = [ "seter-proxy.service" ];
```

For another manager, arrange the equivalent restart only after the new source file is complete. The proxy fails closed if any configured source is absent or any runtime value is invalid. Because one proxy serves all workspaces, one invalid configured credential prevents that host proxy from becoming ready.

## Enforcement rules

A request is eligible for injection only when all of the following hold:

- the source address belongs to the workspace that owns the binding;
- the destination is in that workspace's intercepted `egress.httpHosts`;
- the request uses HTTPS;
- TLS SNI and HTTP authority match;
- the secret is bound to that exact normalized hostname;
- the placeholder occurs in one of the secret's configured header values; and
- normal public-address pinning succeeds.

The proxy rewrites the in-memory request after those policy checks, then verifies upstream TLS before transmitting the request. A certificate failure therefore prevents the real value from reaching the upstream server.

A recognized placeholder in a configured header receives HTTP 403 rather than injection when sent over cleartext HTTP or to another otherwise-allowed host. Requests containing several recognized placeholders are validated atomically before any replacement.

Secrets cannot bind to `passthroughHosts`: passthrough traffic remains encrypted to the proxy. Routing, framing, and hop-by-hop headers such as `Host`, `Content-Length`, `Connection`, `Transfer-Encoding`, and `Proxy-Authorization` cannot be injection targets.

Seter deliberately does not replace placeholders in:

- URL paths or query strings;
- request bodies;
- unconfigured headers;
- direct TCP connections; or
- TLS passthrough connections.

Prefer an authorization or API-key header. Secrets in URLs are routinely copied into logs and browser history, while request-body rewriting requires content-type-specific parsing and buffering.

## Auditing and response redaction

An allowed request that injected values records only policy names:

```json
{"decision":"allow","host":"api.github.com","injectedSecrets":["githubToken"],"workspace":"project"}
```

Audit records never include configured header values, runtime credential values, or source paths. Response-redaction events similarly list only secret names.

Response redaction is best-effort hygiene, not a data-loss-prevention boundary. It catches exact values in decoded response bodies and ordinary response headers. It cannot reliably catch a service that:

- encodes, hashes, encrypts, splits, or transforms a value;
- exposes information derived from the credential;
- stores the value and returns it through another service; or
- uses the credential to perform an authorized destructive action.

Treat every bound destination as part of the credential's trust boundary. Use a separate, least-privilege credential per workspace, restrict it to the required repositories or API capabilities, and rotate it independently.

The single host proxy necessarily has access to the runtime credentials for all configured workspaces. A compromise of that host service is therefore outside the isolation provided between guests.

## Operational checks

Inspect policy decisions without printing credentials:

```console
journalctl -u seter-proxy.service | grep 'seter-audit'
```

After changing a binding, rebuild and activate the host NixOS configuration. After changing only a runtime value, restart the proxy:

```console
sudo systemctl restart seter-proxy.service
systemctl is-active seter-proxy.service
```

If startup fails, inspect the service journal for a missing credential name or a format error. Error messages identify policy and credential names but do not print values.

Common request failures are:

- **403, only over HTTPS:** the application used `http://`; change it to `https://`.
- **403, not bound to host:** add the exact destination only after reviewing it, or correct the application's endpoint.
- **Placeholder reaches the service:** the header is not configured, the guest and host placeholders differ, or the application encoded the placeholder before sending it.
- **TLS verification failure:** fix the upstream certificate or host trust; do not disable verification to make injection work.
