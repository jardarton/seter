# The workspace network boundary

A workspace reaches only the destinations its registry entry declares. Everything else is denied, including traffic to the host, to other workspaces, and to the LAN.

Four host-owned services enforce this together: an nftables policy at layer 2 and 3, a per-workspace DNS resolver, a transparent HTTP/HTTPS proxy, and a direct-TCP address-set service. Each is unprivileged and each fails closed.

## Requirement: the nftables backend

Seter requires and enables NixOS's native `networking.nftables` backend, so its tables participate in the host's complete atomic firewall transaction.

**This switches the host firewall backend from legacy iptables and may require changes for Docker, libvirt, or other software that manages iptables rules. Review those services before enabling the host module.**

## Layer 2 and layer 3

Every workspace TAP is an isolated bridge port. Host-owned nftables rules:

- bind each TAP to its registered IPv4 and MAC addresses;
- reject forged ARP and IPv4 identities;
- block IPv6 until it has an explicit policy; and
- deny workspace-initiated traffic to the host, to other workspaces, and to routed networks, except for explicitly selected gateway services.

Host-initiated connections such as `seter shell` remain available.

The nftables policy is installed before any TAP can start. A policy-loading failure prevents the workspace runtime from starting. Stopping nftables stops active workspace TAPs before it removes their rules. The boundary does not rely on forwarding being disabled, or on unrelated firewall rules rejecting traffic.

## DNS

A separate unprivileged policy resolver runs on demand for each active workspace behind the bridge gateway. Workspaces may query the gateway over TCP or UDP, but the resolver accepts only names derived from that workspace's configured HTTP, passthrough, and direct-TCP destinations.

Exact grants match only one name. A `*.example.com` pattern matches exactly one subordinate label, and excludes both the apex and deeper names. nftables redirects each registered source address to its own listener, and the listener independently verifies the registered source address. One workspace's destinations therefore do not broaden another workspace's DNS policy.

Only `A` requests cross the policy boundary. The resolver constructs a fresh canonical query before it sends the query to a shared loopback-only dnsmasq cache. Guest-controlled case, message IDs, extra questions, additional sections, and EDNS options therefore cannot reach an upstream resolver. Exact `AAAA` requests receive a local empty response, because IPv6 is out of scope. The resolver refuses other classes and record types, malformed packets, multi-question packets, and non-exact names. Direct DNS to outside resolvers remains blocked over both UDP and TCP.

Set `seter.host.dns.upstreamServers` to explicit IPv4 recursive resolvers, or leave it empty to use the host's existing `/etc/resolv.conf`. Only the loopback caching backend contacts these. Host applications resolve registered workspace hostnames through generated `/etc/hosts` entries; Seter does not replace the host resolver.

Per-workspace rate, burst, concurrency, query-size, and upstream-timeout bounds limit resource abuse.

See [DNS policy](./dns-policy.md) for the wire-level policy and the resource controls.

## Other protocols

DNS is the only generally permitted UDP protocol.

- UDP/443 remains blocked, so HTTP/3 or QUIC cannot bypass the TCP HTTP policy.
- Arbitrary UDP remains unavailable unless a future protocol-specific policy supports it.
- DNS-over-TLS is blocked unless its endpoint is deliberately authorized as direct TCP.
- ICMP and other IP protocol egress remain default-denied.
- IPv6 is deliberately out of scope and blocked at the bridge boundary.

## HTTP and HTTPS interception

A hardened, unprivileged mitmproxy service transparently intercepts registered workspace TCP traffic to ports 80 and 443.

The source IP selects the workspace policy. Only exact names, or bounded single-label Host Patterns in that workspace's HTTP grants, are accepted. The proxy requires the HTTPS SNI and the HTTP host to agree. It then resolves and pins the reviewed hostname, instead of trusting the packet's original destination or a later DNS answer.

Only publicly routed IPv4 answers are accepted. An allowed name therefore cannot rebind the host-side proxy onto loopback, link-local, Seter, or private LAN services.

Denials return HTTP 403 with a policy reason. Raw TCP and HTTP CONNECT tunnels through the interception ports are disabled.

## TLS passthrough

Names and bounded Host Patterns in passthrough grants use the same transparent port, but they bypass TLS interception. The proxy authorizes the ClientHello SNI against that policy, resolves that reviewed name itself instead of trusting the packet destination, and relays the encrypted connection unchanged.

This supports certificate-pinned clients, and it keeps bulk HTTPS payloads out of TLS decryption and HTTP parsing. Encrypted bytes still traverse mitmproxy's userspace TCP relay.

A name cannot be configured for both interception and passthrough, and passthrough does not permit cleartext HTTP.

## Auditing

The proxy writes allow and deny decisions as single-line JSON records prefixed with `seter-audit` in the `seter-proxy.service` journal. Allowed passthrough connections are logged with their SNI, but their encrypted requests remain opaque. Set `seter.host.proxy.logRequests = false` to disable this audit logging.

Intercepted HTTP logs include the URL path, which may contain sensitive query parameters.

The DNS resolver writes its own allow and deny records, prefixed with `seter-dns-audit`, in each workspace's `seter-dns-<workspace>.service` journal. Set `seter.host.dns.logQueries = false` to disable them.

## Proxy service settings

`seter.host.proxy.upstreamCaFile` may provide a custom PEM trust bundle for intercepted upstream HTTPS verification.

The proxy uses fixed UID 60534 for nftables output isolation. Override `seter.host.proxy.uid` if that UID is already allocated locally.

## Direct TCP

A host-owned service resolves direct non-HTTP TCP destinations declared with `allowedTCP` into a separate nftables address-and-port set for each workspace. Set replacement is atomic, and active sets are immediately repopulated after an nftables reload. Every packet remains conditional on the current set, so removing an address also revokes established connections.

Routed connections are narrowly forwarded and masqueraded through NixOS's enabled forwarding firewall. Seter defaults `networking.firewall.filterForward` on, and rejects direct-TCP policy when either the firewall or forward filtering is disabled. Enabling kernel forwarding therefore cannot expose unrelated host interfaces.

DNS-derived destinations must be publicly routed unicast IPv4 addresses. An allowed name therefore cannot rebind onto loopback, link-local, multicast, private LAN, or workspace services. To deliberately authorize a non-public destination, configure its literal IPv4 address rather than a hostname.

Ports 80 and 443 cannot be declared as direct TCP, because they always pass through the HTTP policy proxy.

As with any layer-3 allowlist, destinations that share an IP address and port are indistinguishable.

## Host service relays

Named host daemons can be exposed through fixed TCP relays on the Seter gateway:

```nix
seter.host.gatewayServices.adb = {
  listenPort = 5037;
  targetAddress = "127.0.0.1"; # the only permitted target address
  targetPort = 5037;
};

seter.host.workspaces.android.hostServices = [ "adb" ];
```

A relay can target only IPv4 loopback. It binds only the bridge gateway, runs as a hardened dynamic user, starts on demand with an authorized workspace's TAP, and stops after becoming idle once no authorized TAP needs it.

The Seter nftables chain admits only the exact registered workspace source address, gateway address, protocol, and listener port. Defining a relay does not authorize any workspace by itself. Listener ports must be unique, and they cannot collide with proxy or generated DNS ports.

In the guest, set `ADB_SERVER_SOCKET=tcp:10.100.0.1:5037`, using that guest's configured gateway. Keep the real daemon loopback-only; never make ADB listen on `0.0.0.0`.

Authorization grants the daemon's full protocol capability: workspaces that share one ADB server can see and control the same device inventory. These relays are transport policy, not authentication. Exposing SSH, the Nix daemon, Docker, or another privileged control plane still requires a separately restricted application-level service.

Only TCP loopback targets are supported initially.

## Proxy CA trust

mitmproxy generates its site interception CA once, in persistent `/var/lib/seter-proxy` state. That directory and both private-key formats remain readable only by the unprivileged proxy account. Seter publishes only the public certificate, under `/var/lib/seter-proxy-public/seter-proxy-ca-cert.pem`.

Export and review it, commit only that public certificate to the trusted host configuration, and install it declaratively into every Runner the host deploys:

```console
seter proxy-ca > seter-proxy-ca-cert.pem
# Compare the SHA-256 fingerprint printed on stderr through a trusted channel.
```

```nix
seter.host.proxyCaCertificate =
  builtins.readFile ./seter-proxy-ca-cert.pem;
```

`security.pki.certificates` makes the CA available through the NixOS system trust bundle, which covers tools that use the system OpenSSL trust configuration. Applications with private trust stores must import the same public certificate into that store. This commonly applies to browsers that use private NSS profiles, Java applications with bundled JKS files, and language tools that replace rather than inherit system roots. Certificate-pinned software should use `passthroughHosts` instead.

Never copy `/var/lib/seter-proxy/mitmproxy-ca.pem`. It contains the private signing key, and it must not enter a guest, a repository, or the Nix store.

Back up `/var/lib/seter-proxy` as site security state. If you lose it, the next proxy start generates a new CA, and you must re-export the certificate and rebuild every guest. A compromise requires rotating the CA and rebuilding every guest. HTTPS fails closed while a guest trusts the wrong generation.

## Explicit proxy variables

Network-enabled guests default `HTTP_PROXY`, `HTTPS_PROXY`, and their lower-case equivalents to the host's explicit endpoint at `http://<gateway>:18081`. `NO_PROXY` covers loopback and the guest's own static address. If `seter.host.proxy.explicitPort` is changed, set `seter.guest.proxy` to the matching URL.

These variables are only a compatibility convenience. Transparent redirection still enforces policy for applications that ignore them. Explicit HTTPS CONNECT is restricted to exact reviewed hosts on port 443, and is rechecked at the TLS layer and, for intercepted traffic, at the HTTP layer.
