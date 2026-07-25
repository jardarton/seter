import asyncio
import ipaddress
import json
import socket
import time
from pathlib import Path

from mitmproxy import ctx, http, tls
from mitmproxy.exceptions import OptionsError
from mitmproxy.proxy.mode_specs import RegularMode
from mitmproxy.proxy import server_hooks


class SeterPolicy:
    def __init__(self) -> None:
        self.workspaces: dict[str, dict[str, object]] = {}
        self.server_pins: dict[str, tuple[str, int, str]] = {}
        self.resolve_cache: dict[
            tuple[str, int], tuple[float, tuple[str | None, str | None]]
        ] = {}
        self.resolve_inflight: dict[
            tuple[str, int], asyncio.Task[tuple[str | None, str | None]]
        ] = {}

    def load(self, loader) -> None:
        loader.add_option(
            "seter_policy",
            str,
            "",
            "Path to the Nix-rendered Seter proxy policy",
        )
        loader.add_option(
            "seter_log_requests",
            bool,
            True,
            "Log HTTP requests and TLS policy decisions",
        )

    def configure(self, updated: set[str]) -> None:
        if "seter_policy" not in updated:
            return

        policy_path = ctx.options.seter_policy
        if not policy_path:
            raise OptionsError("seter_policy must name a policy file")

        try:
            policy = json.loads(Path(policy_path).read_text())
            if policy.get("version") != 1:
                raise ValueError("unsupported policy version")
            workspaces = policy["workspaces"]
            if not isinstance(workspaces, dict):
                raise ValueError("workspaces must be an object")

            parsed: dict[str, dict[str, object]] = {}
            for address, workspace in workspaces.items():
                name = workspace["name"]
                http_hosts = workspace["httpHosts"]
                passthrough_hosts = workspace["passthroughHosts"]
                if (
                    not isinstance(name, str)
                    or not isinstance(http_hosts, list)
                    or not isinstance(passthrough_hosts, list)
                ):
                    raise ValueError("invalid workspace policy")
                parsed[address] = {
                    "name": name,
                    "httpHosts": frozenset(
                        self._normalize(host) for host in http_hosts
                    ),
                    "passthroughHosts": frozenset(
                        self._normalize(host) for host in passthrough_hosts
                    ),
                }
            self.workspaces = parsed
            self.resolve_cache.clear()
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise OptionsError(f"cannot load Seter policy: {error}") from error

    @staticmethod
    def _normalize(host: object) -> str:
        if not isinstance(host, str):
            return ""
        return host.rstrip(".").lower()

    def _workspace(self, client_ip: str) -> dict[str, object] | None:
        return self.workspaces.get(client_ip)

    @staticmethod
    async def _lookup_public_ipv4(
        host: str, port: int
    ) -> tuple[str | None, str | None]:
        """Resolve a public-unicast address without blocking mitmproxy's loop."""
        try:
            answers = await asyncio.get_running_loop().getaddrinfo(
                host, port, family=socket.AF_INET, type=socket.SOCK_STREAM
            )
        except OSError as error:
            return None, f"host {host!r} could not be resolved: {error}"

        addresses = list(dict.fromkeys(answer[4][0] for answer in answers))
        public_addresses = [
            address
            for address in addresses
            if (
                ipaddress.ip_address(address).is_global
                and not ipaddress.ip_address(address).is_multicast
            )
        ]
        if not public_addresses:
            return None, f"host {host!r} did not resolve to a public IPv4 address"
        return public_addresses[0], None

    async def _resolve_public_ipv4(
        self, host: str, port: int
    ) -> tuple[str | None, str | None]:
        """Resolve and briefly cache a hostname while pinning each connection."""
        key = (host, port)
        now = time.monotonic()
        cached = self.resolve_cache.get(key)
        if cached is not None and cached[0] > now:
            return cached[1]

        task = self.resolve_inflight.get(key)
        if task is None:
            task = asyncio.create_task(self._lookup_public_ipv4(host, port))
            self.resolve_inflight[key] = task

        try:
            # One client disconnect must not cancel a lookup shared by other
            # connections for the same reviewed host.
            result = await asyncio.shield(task)
        finally:
            if task.done() and self.resolve_inflight.get(key) is task:
                self.resolve_inflight.pop(key, None)

        # Successful lookups are shared briefly across new connections. Cache
        # failures only long enough to bound a denial flood without turning a
        # transient resolver outage into a long-lived policy failure.
        ttl = 60.0 if result[0] is not None else 5.0
        self.resolve_cache[key] = (time.monotonic() + ttl, result)
        return result

    @staticmethod
    def _audit(record: dict[str, object]) -> None:
        if ctx.options.seter_log_requests:
            ctx.log.info(
                "seter-audit "
                + json.dumps(record, separators=(",", ":"), sort_keys=True)
            )

    @staticmethod
    def _client_ip(flow: http.HTTPFlow) -> str:
        return flow.client_conn.peername[0]

    def server_disconnected(
        self, data: server_hooks.ServerConnectionHookData
    ) -> None:
        self.server_pins.pop(data.server.id, None)

    def server_connect_error(
        self, data: server_hooks.ServerConnectionHookData
    ) -> None:
        self.server_pins.pop(data.server.id, None)

    async def http_connect(self, flow: http.HTTPFlow) -> None:
        """Authorize the convenience explicit proxy's HTTPS CONNECT request.

        Transparent clients never need CONNECT. Regular proxy clients do, but
        they may only establish a TLS tunnel to an exact reviewed host on port
        443. The following ClientHello and HTTP request remain independently
        checked, so this endpoint is a convenience rather than a weaker policy
        path.
        """
        client_ip = self._client_ip(flow)
        workspace = self._workspace(client_ip)
        host = self._normalize(flow.request.host)
        port = flow.request.port
        decision = "deny"
        reason = "source is not a registered Seter workspace"

        if not isinstance(flow.client_conn.proxy_mode, RegularMode):
            reason = "HTTP CONNECT is only available on the explicit proxy endpoint"
        elif workspace is not None:
            allowed_hosts = workspace["httpHosts"] | workspace["passthroughHosts"]
            if port != 443:
                reason = "explicit HTTP CONNECT is restricted to port 443"
            elif host not in allowed_hosts:
                reason = (
                    f"host {host or '<missing>'!r} is not in this workspace's "
                    "HTTP or TLS-passthrough allowlist"
                )
            else:
                address, error = await self._resolve_public_ipv4(host, port)
                if error is not None:
                    reason = error
                else:
                    assert address is not None
                    decision = "allow"
                    reason = "CONNECT host is allowlisted"
                    self.server_pins[flow.server_conn.id] = (host, port, address)
                    # Resolve the reviewed authority ourselves rather than
                    # allowing mitmproxy to trust the client's DNS result.
                    flow.server_conn.address = (address, port)
                    flow.server_conn.sni = host

        self._audit(
            {
                "workspace": workspace["name"] if workspace is not None else None,
                "source": client_ip,
                "decision": decision,
                "method": "CONNECT",
                "host": host,
                "port": port,
                "reason": reason,
            }
        )

        if decision == "deny":
            flow.response = http.Response.make(
                403,
                f"Seter network policy denied this proxy tunnel: {reason}\n",
                {
                    "Content-Type": "text/plain; charset=utf-8",
                    "Cache-Control": "no-store",
                },
            )

    async def tls_clienthello(self, data: tls.ClientHelloData) -> None:
        """Pin authorized TLS connections to their reviewed policy hostname.

        mitmproxy runs with lazy upstream connections and without upstream
        certificate probing, so denied ClientHellos do not contact their
        original destination before the HTTP hook can return a useful 403.
        """
        client_ip = data.context.client.peername[0]
        workspace = self._workspace(client_ip)
        sni = self._normalize(data.client_hello.sni)
        if workspace is None:
            self._audit(
                {
                    "workspace": None,
                    "source": client_ip,
                    "decision": "deny",
                    "protocol": "tls",
                    "host": sni,
                    "reason": "source is not a registered Seter workspace",
                }
            )
            return

        if sni in workspace["passthroughHosts"]:
            # The original packet destination is attacker-controlled. Resolve
            # the allowlisted SNI once, reject host-private destinations, and
            # relay only to the resulting pinned address.
            address, error = await self._resolve_public_ipv4(sni, 443)
            if error is not None:
                self._audit(
                    {
                        "workspace": workspace["name"],
                        "source": client_ip,
                        "decision": "deny",
                        "protocol": "tls-passthrough",
                        "host": sni,
                        "reason": error,
                    }
                )
                return
            assert address is not None
            data.context.server.address = (address, 443)
            data.context.server.sni = sni
            data.ignore_connection = True
            self._audit(
                {
                    "workspace": workspace["name"],
                    "source": client_ip,
                    "decision": "allow",
                    "protocol": "tls-passthrough",
                    "host": sni,
                    "upstream": address,
                    "reason": "SNI is allowlisted for TLS passthrough",
                }
            )
        elif sni not in workspace["httpHosts"]:
            self._audit(
                {
                    "workspace": workspace["name"],
                    "source": client_ip,
                    "decision": "deny",
                    "protocol": "tls",
                    "host": sni,
                    "reason": f"SNI {sni or '<missing>'!r} is not allowlisted",
                }
            )

    async def request(self, flow: http.HTTPFlow) -> None:
        client_ip = self._client_ip(flow)
        workspace = self._workspace(client_ip)
        # In transparent mode Request.host is the packet's original IP.
        # pretty_host prefers the HTTP Host/:authority value, which we then
        # validate and use to replace—not merely annotate—the upstream target.
        host = self._normalize(flow.request.pretty_host)
        scheme = flow.request.scheme.lower()
        decision = "deny"
        reason = "source is not a registered Seter workspace"

        # CONNECT is authorized and audited in http_connect before mitmproxy
        # starts the nested TLS flow. It is never forwarded as an ordinary
        # request, and a denial already carries its own 403 response.
        if flow.request.method.upper() == "CONNECT":
            return

        if workspace is not None:
            if scheme not in ("http", "https"):
                reason = f"unsupported URL scheme {scheme!r}"
            elif host not in workspace["httpHosts"]:
                reason = f"host {host or '<missing>'!r} is not in this workspace's HTTP allowlist"
            elif scheme == "https" and self._normalize(flow.client_conn.sni) != host:
                reason = "HTTPS SNI and HTTP host do not match"
            else:
                port = 443 if scheme == "https" else 80
                pin = self.server_pins.get(flow.server_conn.id)
                if flow.server_conn.connected:
                    if pin is None:
                        reason = "upstream connection was established before policy evaluation"
                    elif pin[:2] != (host, port):
                        reason = "persistent upstream connection is pinned to a different host"
                    else:
                        decision = "allow"
                        reason = "host is allowlisted and matches the pinned upstream connection"
                else:
                    address, error = await self._resolve_public_ipv4(host, port)
                    if error is not None:
                        reason = error
                    else:
                        assert address is not None
                        decision = "allow"
                        reason = "host is allowlisted"
                        self.server_pins[flow.server_conn.id] = (host, port, address)
                        # Never trust the packet's original destination or a
                        # later DNS answer. Connect to this reviewed address.
                        flow.server_conn.address = (address, port)
                        flow.server_conn.sni = host if scheme == "https" else None

                if decision == "allow":
                    # Keep the logical HTTP authority on the reviewed name,
                    # including when a pinned connection is reused.
                    flow.request.host = host
                    flow.request.port = port

        workspace_name = workspace["name"] if workspace is not None else None
        self._audit(
            {
                "workspace": workspace_name,
                "source": client_ip,
                "decision": decision,
                "method": flow.request.method,
                "host": host,
                "path": flow.request.path,
                "reason": reason,
            }
        )

        if decision == "deny":
            flow.response = http.Response.make(
                403,
                f"Seter network policy denied this request: {reason}\n",
                {
                    "Content-Type": "text/plain; charset=utf-8",
                    "Cache-Control": "no-store",
                },
            )


addons = [SeterPolicy()]
