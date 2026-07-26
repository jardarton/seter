# DNS policy

Seter treats guest DNS as part of the egress boundary, not merely as a name-resolution convenience. Each active workspace receives a dedicated unprivileged listener on an internal high port. nftables redirects that workspace's TCP and UDP requests for gateway port 53 to its listener and prevents access to another workspace's listener.

## Allowed names

The listener derives its allowlist from the workspace's intercepted HTTP hosts, TLS-passthrough hosts, and named direct-TCP destinations. Literal IPv4 direct-TCP destinations are omitted because they require no DNS.

Matching is exact, case-insensitive, and insensitive to one final DNS root dot. For example, `api.example.com` permits `API.EXAMPLE.COM.` but not `child.api.example.com`.

Only Internet-class `A` queries are forwarded. An exact `AAAA` query receives a local `NOERROR` response with no answers so dual-stack clients can immediately continue with IPv4. Other classes and record types receive `REFUSED`. IPv6 and general UDP egress are out of scope.

## Canonical forwarding

A permitted packet is never relayed byte-for-byte. The frontend creates a new lower-case, single-question `A` request with a fresh message ID and no EDNS data before sending it to a shared loopback-only dnsmasq cache. It copies only the recursive response back to a bounded client response.

This prevents the guest from using these fields as data channels to an upstream resolver:

- mixed-case QNAME encoding
- arbitrary message IDs
- multiple questions
- answer, authority, or additional sections
- arbitrary query types and classes
- EDNS client-subnet, private options, and padding

The backend handles caching, recursive-server selection, CNAME answers, UDP truncation, and TCP retry. It retains dnsmasq's rebinding protection. Proxy and direct-TCP policy still independently resolve and validate destinations, so guest-visible DNS is never authoritative for an allowed connection.

Malformed requests receive `FORMERR` when enough of the header is available. Non-exact names and otherwise parseable policy violations receive `REFUSED`. Oversized or idle TCP requests fail closed.

## Resource limits

The following host options apply per workspace unless noted:

- `seter.host.dns.queriesPerSecond`
- `seter.host.dns.queryBurst`
- `seter.host.dns.maxConcurrentQueries`
- `seter.host.dns.upstreamTimeoutSeconds`
- `seter.host.dns.upstreamServers`
- `seter.host.dns.upstreamPort` (shared loopback backend)

The frontend also caps UDP and TCP query sizes, UDP response size, TCP idle time, memory, tasks, file descriptors, and journal rate. Rate or concurrency exhaustion returns a policy failure instead of forwarding upstream.

## Auditing

With `seter.host.dns.logQueries = true`, decisions appear in the matching `seter-dns-<workspace>.service` journal as single-line JSON prefixed with `seter-dns-audit`. Records contain workspace, source, transport, normalized name, query type, decision, and reason. Raw packets and EDNS values are not logged.

## Unsupported protocols

Direct DNS to external UDP or TCP port 53 is blocked. DNS-over-TLS is blocked unless a destination is deliberately authorized as direct TCP. UDP/443 remains blocked so QUIC and HTTP/3 cannot bypass the TCP HTTP proxy. Arbitrary UDP, ICMP egress, and other IP protocols remain default-denied.

An explicitly allowlisted HTTPS service is within that workspace's destination trust boundary. If such a service intentionally exposes DNS-over-HTTPS, generic HTTP policy cannot distinguish that capability from its other approved API operations.
