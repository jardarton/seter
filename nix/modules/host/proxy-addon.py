import asyncio
import ipaddress
import json
import os
import re
import socket
import time
from pathlib import Path

from mitmproxy import ctx, http, tls
from mitmproxy.exceptions import OptionsError
from mitmproxy.proxy.mode_specs import RegularMode
from mitmproxy.proxy import server_hooks


class SeterPolicy:
    _MIN_CREDENTIAL_BYTES = 8
    _MAX_CREDENTIAL_BYTES = 16 * 1024
    _CREDENTIAL_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{0,254}")
    _HEADER_NAME = re.compile(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+")
    _HOST_NAME = re.compile(
        r"(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9])"
    )
    _PLACEHOLDER = re.compile(r"seter-placeholder-[A-Za-z0-9_-]{16,}")
    _SECRET_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_-]{0,62}")
    _PROHIBITED_SECRET_HEADERS = frozenset(
        {
            "connection",
            "content-length",
            "host",
            "keep-alive",
            "proxy-authenticate",
            "proxy-authorization",
            "proxy-connection",
            "te",
            "trailer",
            "transfer-encoding",
            "upgrade",
        }
    )
    _RESPONSE_FRAMING_HEADERS = frozenset(
        {
            "connection",
            "content-encoding",
            "content-length",
            "keep-alive",
            "te",
            "trailer",
            "transfer-encoding",
            "upgrade",
        }
    )
    _REPOSITORY_SMART_HTTP_SUFFIXES = frozenset(
        {
            "/git-receive-pack",
            "/git-upload-pack",
            "/info/refs",
        }
    )

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
        loader.add_option(
            "seter_ready_file",
            str,
            "",
            "Runtime readiness marker created after policy and credentials load",
        )

    def configure(self, updated: set[str]) -> None:
        if "seter_policy" not in updated:
            return

        policy_path = ctx.options.seter_policy
        if not policy_path:
            raise OptionsError("seter_policy must name a policy file")
        ready_path = ctx.options.seter_ready_file
        if not ready_path:
            raise OptionsError("seter_ready_file must name a runtime path")

        try:
            Path(ready_path).unlink(missing_ok=True)
            policy = json.loads(Path(policy_path).read_text())
            if policy.get("version") != 3:
                raise ValueError("unsupported policy version")
            workspaces = policy["workspaces"]
            if not isinstance(workspaces, dict):
                raise ValueError("workspaces must be an object")

            parsed: dict[str, dict[str, object]] = {}
            credential_names: set[str] = set()
            credentials_directory = os.environ.get("CREDENTIALS_DIRECTORY")
            for address, workspace in workspaces.items():
                name = workspace["name"]
                http_hosts = workspace["httpHosts"]
                passthrough_hosts = workspace["passthroughHosts"]
                repository = workspace["repository"]
                secrets = workspace["secrets"]
                if (
                    not isinstance(name, str)
                    or not isinstance(http_hosts, list)
                    or not all(
                        isinstance(host, str)
                        and self._HOST_NAME.fullmatch(host) is not None
                        for host in http_hosts
                    )
                    or not isinstance(passthrough_hosts, list)
                    or not all(
                        isinstance(host, str)
                        and self._HOST_NAME.fullmatch(host) is not None
                        for host in passthrough_hosts
                    )
                    or not isinstance(secrets, dict)
                    or not isinstance(repository, dict)
                ):
                    raise ValueError("invalid workspace policy")

                normalized_http_hosts = frozenset(
                    self._normalize(host) for host in http_hosts
                )
                normalized_passthrough_hosts = frozenset(
                    self._normalize(host) for host in passthrough_hosts
                )
                if (
                    len(normalized_http_hosts) != len(http_hosts)
                    or len(normalized_passthrough_hosts) != len(passthrough_hosts)
                    or normalized_http_hosts & normalized_passthrough_hosts
                ):
                    raise ValueError("invalid workspace host policy")

                parsed_secrets: dict[str, dict[str, object]] = {}
                placeholders: list[str] = []
                for secret_name, secret in secrets.items():
                    if not isinstance(secret, dict):
                        raise ValueError(f"invalid secret policy for {secret_name!r}")
                    credential = secret.get("credential")
                    placeholder = secret.get("placeholder")
                    hosts = secret.get("hosts")
                    headers = secret.get("headers")
                    if (
                        not isinstance(secret_name, str)
                        or self._SECRET_NAME.fullmatch(secret_name) is None
                        or not isinstance(credential, str)
                        or self._CREDENTIAL_NAME.fullmatch(credential) is None
                        or credential in credential_names
                        or not isinstance(placeholder, str)
                        or self._PLACEHOLDER.fullmatch(placeholder) is None
                        or not isinstance(hosts, list)
                        or not hosts
                        or not all(
                            isinstance(host, str)
                            and self._HOST_NAME.fullmatch(host) is not None
                            for host in hosts
                        )
                        or not isinstance(headers, list)
                        or not headers
                        or not all(
                            isinstance(header, str)
                            and self._HEADER_NAME.fullmatch(header) is not None
                            for header in headers
                        )
                    ):
                        raise ValueError(f"invalid secret policy for {secret_name!r}")

                    normalized_hosts = frozenset(
                        self._normalize(host) for host in hosts
                    )
                    normalized_headers = frozenset(
                        header.lower() for header in headers
                    )
                    if (
                        len(normalized_hosts) != len(hosts)
                        or not normalized_hosts <= normalized_http_hosts
                        or len(normalized_headers) != len(headers)
                        or normalized_headers & self._PROHIBITED_SECRET_HEADERS
                        or any(
                            placeholder in other or other in placeholder
                            for other in placeholders
                        )
                    ):
                        raise ValueError(f"invalid secret policy for {secret_name!r}")

                    credential_names.add(credential)
                    placeholders.append(placeholder)
                    if not credentials_directory:
                        raise ValueError(
                            f"credential directory is unavailable for {secret_name!r}"
                        )
                    credential_value = self._read_credential(
                        Path(credentials_directory), credential
                    )
                    parsed_secrets[secret_name] = {
                        "credential": credential,
                        "placeholder": placeholder,
                        "hosts": normalized_hosts,
                        "headers": normalized_headers,
                        "value": credential_value,
                    }

                repository_host = self._normalize(repository.get("host"))
                repository_path = repository.get("path")
                repository_credential = repository.get("credential")
                repository_path_lower = (
                    repository_path.lower()
                    if isinstance(repository_path, str)
                    else ""
                )
                if (
                    self._HOST_NAME.fullmatch(repository_host) is None
                    or repository_host not in normalized_http_hosts
                    or not isinstance(repository_path, str)
                    or not repository_path.startswith("/")
                    or "?" in repository_path
                    or "#" in repository_path
                    or repository_path.rstrip("/") == ""
                    or any(
                        component in ("", ".", "..")
                        for component in repository_path.split("/")[1:]
                    )
                    or any(
                        encoded in repository_path_lower
                        for encoded in ("%2e", "%2f", "%5c")
                    )
                    or (
                        repository_credential is not None
                        and (
                            not isinstance(repository_credential, str)
                            or repository_credential not in parsed_secrets
                            or repository_host
                            not in parsed_secrets[repository_credential]["hosts"]
                            or "authorization"
                            not in parsed_secrets[repository_credential]["headers"]
                        )
                    )
                ):
                    raise ValueError(f"invalid repository policy for {name!r}")
                parsed[address] = {
                    "name": name,
                    "httpHosts": normalized_http_hosts,
                    "passthroughHosts": normalized_passthrough_hosts,
                    "repository": {
                        "host": repository_host,
                        "path": repository_path.rstrip("/"),
                        "credential": repository_credential,
                    },
                    # Credential values came from systemd's private runtime
                    # credential directory, never from this Nix-store policy.
                    "secrets": parsed_secrets,
                }
            self.workspaces = parsed
            self.resolve_cache.clear()
            Path(ready_path).touch(mode=0o600)
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise OptionsError(f"cannot load Seter policy: {error}") from error

    @staticmethod
    def _normalize(host: object) -> str:
        if not isinstance(host, str):
            return ""
        return host.rstrip(".").lower()

    def _workspace(self, client_ip: str) -> dict[str, object] | None:
        return self.workspaces.get(client_ip)

    @classmethod
    def _read_credential(cls, directory: Path, name: str) -> str:
        value = (directory / name).read_bytes()
        # Text secret managers commonly terminate files with one line ending.
        # Remove only that terminator; other whitespace remains significant.
        if value.endswith(b"\r\n"):
            value = value[:-2]
        elif value.endswith(b"\n"):
            value = value[:-1]
        if len(value) < cls._MIN_CREDENTIAL_BYTES:
            raise ValueError(f"credential {name!r} is shorter than the minimum length")
        if len(value) > cls._MAX_CREDENTIAL_BYTES:
            raise ValueError(f"credential {name!r} exceeds the size limit")
        credential = value.decode("ascii")
        if any(
            ord(character) < 0x20 or ord(character) == 0x7F
            for character in credential
        ):
            raise ValueError(f"credential {name!r} contains a control character")
        return credential

    @staticmethod
    def _inject_request_secrets(
        flow: http.HTTPFlow,
        workspace: dict[str, object],
        host: str,
        scheme: str,
        path: str,
    ) -> tuple[list[str], str | None]:
        """Replace configured header placeholders after destination approval.

        Validation happens before mutation so a request containing multiple
        placeholders is either rewritten completely or denied unchanged.
        Each header is rewritten from its original value with one regex pass,
        preventing one credential value from being interpreted as another
        placeholder.
        """
        matched: list[tuple[str, dict[str, object]]] = []
        for secret_name, secret in workspace["secrets"].items():
            placeholder = secret["placeholder"]
            if any(
                placeholder in value
                for header in secret["headers"]
                for value in flow.request.headers.get_all(header)
            ):
                matched.append((secret_name, secret))

        if not matched:
            return [], None

        for secret_name, secret in matched:
            if scheme != "https":
                return [], f"secret {secret_name!r} may only be injected over HTTPS"
            if host not in secret["hosts"]:
                return [], f"secret {secret_name!r} is not bound to host {host!r}"
            repository = workspace["repository"]
            if secret_name == repository["credential"]:
                request_path = path.partition("?")[0]
                repository_path = repository["path"]
                suffix = request_path.removeprefix(repository_path)
                if host != repository["host"] or not (
                    request_path == repository_path
                    or (
                        request_path.startswith(repository_path + "/")
                        and suffix in SeterPolicy._REPOSITORY_SMART_HTTP_SUFFIXES
                    )
                ):
                    return [], (
                        f"repository credential {secret_name!r} is not bound to "
                        f"path {request_path!r}"
                    )

        headers = frozenset(
            header for _, secret in matched for header in secret["headers"]
        )
        for header in headers:
            replacements = {
                secret["placeholder"]: secret["value"]
                for _, secret in matched
                if header in secret["headers"]
            }
            pattern = re.compile(
                "|".join(
                    re.escape(placeholder)
                    for placeholder in sorted(replacements, key=len, reverse=True)
                )
            )
            values = flow.request.headers.get_all(header)
            if values:
                flow.request.headers.set_all(
                    header,
                    [
                        pattern.sub(
                            lambda match: replacements[match.group(0)], value
                        )
                        for value in values
                    ],
                )
        return sorted(secret_name for secret_name, _ in matched), None

    @classmethod
    def _redact_response_secrets(
        cls,
        flow: http.HTTPFlow,
        workspace: dict[str, object],
        host: str,
        scheme: str,
    ) -> list[str]:
        """Replace exact bound credential values before a response reaches a guest.

        Apply this to every HTTPS response from a secret-bound host, not only
        the request that injected a placeholder. This prevents straightforward
        reflection on a later request. It remains a best-effort boundary:
        upstreams can transform a credential or disclose credential-derived
        information that no generic byte replacement can recognize.
        """
        if scheme != "https":
            return []

        bound = [
            (secret_name, secret)
            for secret_name, secret in workspace["secrets"].items()
            if host in secret["hosts"]
        ]
        if not bound:
            return []

        # Multiple secret names may intentionally resolve to the same runtime
        # value. Redact that value once and report every matching policy name.
        replacements: dict[str, str] = {}
        names_by_value: dict[str, set[str]] = {}
        for secret_name, secret in sorted(bound):
            value = secret["value"]
            replacements.setdefault(value, secret["placeholder"])
            names_by_value.setdefault(value, set()).add(secret_name)

        ordered_values = sorted(replacements, key=len, reverse=True)
        text_pattern = re.compile(
            "|".join(re.escape(value) for value in ordered_values)
        )
        byte_replacements = {
            value.encode("ascii"): placeholder.encode("ascii")
            for value, placeholder in replacements.items()
        }
        byte_pattern = re.compile(
            b"|".join(
                re.escape(value)
                for value in sorted(byte_replacements, key=len, reverse=True)
            )
        )
        redacted_values: set[str] = set()

        def replace_text(match: re.Match[str]) -> str:
            value = match.group(0)
            redacted_values.add(value)
            return replacements[value]

        for header in frozenset(flow.response.headers.keys()):
            if header.lower() in cls._RESPONSE_FRAMING_HEADERS:
                continue
            values = flow.response.headers.get_all(header)
            rewritten = [text_pattern.sub(replace_text, value) for value in values]
            if rewritten != values:
                flow.response.headers.set_all(header, rewritten)

        content = flow.response.get_content(strict=False)
        if content is not None:
            redacted_byte_values: set[bytes] = set()

            def replace_bytes(match: re.Match[bytes]) -> bytes:
                value = match.group(0)
                redacted_byte_values.add(value)
                return byte_replacements[value]

            rewritten_content = byte_pattern.sub(replace_bytes, content)
            if rewritten_content != content:
                flow.response.set_content(rewritten_content)
            redacted_values.update(
                value.decode("ascii") for value in redacted_byte_values
            )

        return sorted(
            secret_name
            for value in redacted_values
            for secret_name in names_by_value[value]
        )

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
        injected_secrets: list[str] = []

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
                    injected_secrets, injection_error = self._inject_request_secrets(
                        flow, workspace, host, scheme, flow.request.path
                    )
                    if injection_error is not None:
                        decision = "deny"
                        reason = injection_error

                if decision == "allow":
                    # Keep the logical HTTP authority on the reviewed name,
                    # including when a pinned connection is reused.
                    flow.request.host = host
                    flow.request.port = port

        workspace_name = workspace["name"] if workspace is not None else None
        audit_record = {
            "workspace": workspace_name,
            "source": client_ip,
            "decision": decision,
            "method": flow.request.method,
            "host": host,
            "path": flow.request.path,
            "reason": reason,
        }
        if injected_secrets:
            audit_record["injectedSecrets"] = injected_secrets
        self._audit(audit_record)

        if decision == "deny":
            flow.response = http.Response.make(
                403,
                f"Seter network policy denied this request: {reason}\n",
                {
                    "Content-Type": "text/plain; charset=utf-8",
                    "Cache-Control": "no-store",
                },
            )

    def response(self, flow: http.HTTPFlow) -> None:
        client_ip = self._client_ip(flow)
        workspace = self._workspace(client_ip)
        if workspace is None:
            return

        host = self._normalize(flow.request.pretty_host)
        scheme = flow.request.scheme.lower()
        redacted_secrets = self._redact_response_secrets(
            flow, workspace, host, scheme
        )
        if redacted_secrets:
            self._audit(
                {
                    "workspace": workspace["name"],
                    "source": client_ip,
                    "event": "response-redaction",
                    "host": host,
                    "path": flow.request.path,
                    "redactedSecrets": redacted_secrets,
                }
            )


addons = [SeterPolicy()]
