#!/usr/bin/env python3
"""Strict per-workspace DNS policy frontend for Seter.

The guest-facing listener accepts only exact, configured names. Permitted A
queries are reconstructed before they reach the shared caching resolver, so
case, additional sections, EDNS options, and other guest-controlled wire data
cannot become an upstream exfiltration channel.
"""

from __future__ import annotations

import argparse
import asyncio
import ipaddress
import json
import socket
import struct
import sys
import time
from pathlib import Path
from typing import Any

import dns.asyncquery
import dns.flags
import dns.message
import dns.opcode
import dns.rcode
import dns.rdataclass
import dns.rdatatype


MAX_UDP_QUERY_BYTES = 4096
MAX_TCP_QUERY_BYTES = 16384
MAX_UDP_RESPONSE_BYTES = 1232
TCP_CLIENT_TIMEOUT_SECONDS = 10.0


class TokenBucket:
    def __init__(self, rate: int, burst: int):
        self.rate = float(rate)
        self.capacity = float(burst)
        self.tokens = float(burst)
        self.updated = time.monotonic()

    def take(self) -> bool:
        now = time.monotonic()
        self.tokens = min(
            self.capacity,
            self.tokens + (now - self.updated) * self.rate,
        )
        self.updated = now
        if self.tokens < 1.0:
            return False
        self.tokens -= 1.0
        return True


class PolicyServer:
    def __init__(self, config: dict[str, Any]):
        if require_integer(config, "version", 0, 2_147_483_647) != 1:
            raise ValueError("unsupported DNS policy version")
        self.workspace = require_string(config, "workspace")
        self.source_address = str(
            ipaddress.IPv4Address(require_string(config, "sourceAddress"))
        )
        self.allowed_names = frozenset(
            canonical_policy_pattern(name) for name in require_string_list(config, "allowedNames")
        )
        self.backend_address = str(
            ipaddress.IPv4Address(require_string(config, "backendAddress"))
        )
        self.backend_port = require_integer(config, "backendPort", 1, 65535)
        self.log_queries = require_boolean(config, "logQueries")
        self.upstream_timeout = require_number(config, "upstreamTimeoutSeconds", 0.1, 60.0)
        self.max_concurrent = require_integer(config, "maxConcurrentQueries", 1, 4096)
        query_rate = require_integer(config, "queriesPerSecond", 1, 1_000_000)
        query_burst = require_integer(config, "queryBurst", 1, 1_000_000)
        if query_burst < query_rate:
            raise ValueError("queryBurst must be at least queriesPerSecond")

        self.rate_limiter = TokenBucket(query_rate, query_burst)
        self.inflight = 0
        self.tasks: set[asyncio.Task[None]] = set()

    def audit(
        self,
        *,
        source: str,
        decision: str,
        reason: str,
        name: str = "",
        query_type: str = "",
        protocol: str,
    ) -> None:
        if not self.log_queries:
            return
        record = {
            "workspace": self.workspace,
            "source": source,
            "decision": decision,
            "protocol": protocol,
            "name": name,
            "type": query_type,
            "reason": reason,
        }
        print(
            "seter-dns-audit "
            + json.dumps(record, separators=(",", ":"), sort_keys=True),
            flush=True,
        )

    def reserve(self) -> bool:
        if self.inflight >= self.max_concurrent:
            return False
        self.inflight += 1
        return True

    def release(self) -> None:
        self.inflight -= 1

    def spawn_udp(
        self,
        transport: asyncio.DatagramTransport,
        data: bytes,
        peer: tuple[str, int],
    ) -> None:
        source = peer[0]
        if not self.reserve():
            self.audit(
                source=source,
                decision="deny",
                reason="concurrent query limit exceeded",
                protocol="udp",
            )
            response = error_wire(data, dns.rcode.SERVFAIL, tcp=False)
            if response is not None:
                transport.sendto(response, peer)
            return

        async def run() -> None:
            try:
                response = await self.handle_wire(data, source=source, protocol="udp")
                if response is not None:
                    transport.sendto(response, peer)
            finally:
                self.release()

        task = asyncio.create_task(run())
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    async def handle_tcp(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        peer = writer.get_extra_info("peername")
        source = peer[0] if isinstance(peer, tuple) and peer else ""
        if not self.reserve():
            self.audit(
                source=source,
                decision="deny",
                reason="concurrent query limit exceeded",
                protocol="tcp",
            )
            writer.close()
            await writer.wait_closed()
            return

        try:
            while True:
                try:
                    length_wire = await asyncio.wait_for(
                        reader.readexactly(2), timeout=TCP_CLIENT_TIMEOUT_SECONDS
                    )
                except asyncio.IncompleteReadError:
                    break
                except TimeoutError:
                    self.audit(
                        source=source,
                        decision="deny",
                        reason="idle TCP DNS client timed out",
                        protocol="tcp",
                    )
                    break

                length = struct.unpack("!H", length_wire)[0]
                if length == 0 or length > MAX_TCP_QUERY_BYTES:
                    self.audit(
                        source=source,
                        decision="deny",
                        reason="invalid TCP DNS message length",
                        protocol="tcp",
                    )
                    break
                try:
                    data = await asyncio.wait_for(
                        reader.readexactly(length), timeout=TCP_CLIENT_TIMEOUT_SECONDS
                    )
                except (asyncio.IncompleteReadError, TimeoutError):
                    break

                response = await self.handle_wire(data, source=source, protocol="tcp")
                if response is None:
                    break
                writer.write(struct.pack("!H", len(response)) + response)
                await writer.drain()
        finally:
            self.release()
            writer.close()
            await writer.wait_closed()

    async def handle_wire(self, data: bytes, *, source: str, protocol: str) -> bytes | None:
        tcp = protocol == "tcp"
        maximum = MAX_TCP_QUERY_BYTES if tcp else MAX_UDP_QUERY_BYTES
        if len(data) > maximum:
            self.audit(
                source=source,
                decision="deny",
                reason="DNS query exceeds the size limit",
                protocol=protocol,
            )
            return error_wire(data, dns.rcode.FORMERR, tcp=tcp)

        if source != self.source_address:
            self.audit(
                source=source,
                decision="deny",
                reason="source is not the registered workspace address",
                protocol=protocol,
            )
            return error_wire(data, dns.rcode.REFUSED, tcp=tcp)

        if not self.rate_limiter.take():
            self.audit(
                source=source,
                decision="deny",
                reason="query rate limit exceeded",
                protocol=protocol,
            )
            return error_wire(data, dns.rcode.REFUSED, tcp=tcp)

        try:
            query = dns.message.from_wire(data, ignore_trailing=False)
        except Exception as error:
            self.audit(
                source=source,
                decision="deny",
                reason=f"malformed DNS query: {type(error).__name__}",
                protocol=protocol,
            )
            return error_wire(data, dns.rcode.FORMERR, tcp=tcp)

        if query.flags & dns.flags.QR:
            self.audit(
                source=source,
                decision="deny",
                reason="DNS responses are not accepted as queries",
                protocol=protocol,
            )
            return error_wire(data, dns.rcode.REFUSED, tcp=tcp)
        if query.opcode() != dns.opcode.QUERY:
            return self.deny(
                query,
                source=source,
                protocol=protocol,
                reason="only standard DNS queries are accepted",
                rcode=dns.rcode.REFUSED,
                tcp=tcp,
            )
        if len(query.question) != 1:
            return self.deny(
                query,
                source=source,
                protocol=protocol,
                reason="exactly one DNS question is required",
                rcode=dns.rcode.REFUSED,
                tcp=tcp,
            )
        if query.answer or query.authority or query.additional:
            return self.deny(
                query,
                source=source,
                protocol=protocol,
                reason="DNS query answer and authority sections must be empty",
                rcode=dns.rcode.REFUSED,
                tcp=tcp,
            )

        question = query.question[0]
        name = question.name.canonicalize().to_text(omit_final_dot=True)
        query_type = dns.rdatatype.to_text(question.rdtype)
        if question.rdclass != dns.rdataclass.IN:
            return self.deny(
                query,
                source=source,
                protocol=protocol,
                reason="only the IN DNS class is accepted",
                name=name,
                query_type=query_type,
                rcode=dns.rcode.REFUSED,
                tcp=tcp,
            )
        if not policy_name_allowed(self.allowed_names, name):
            return self.deny(
                query,
                source=source,
                protocol=protocol,
                reason="name is not exactly allowlisted or matched by an allowed Host Pattern",
                name=name,
                query_type=query_type,
                rcode=dns.rcode.REFUSED,
                tcp=tcp,
            )

        if question.rdtype == dns.rdatatype.AAAA:
            self.audit(
                source=source,
                decision="allow",
                reason="IPv4-only policy returned local NODATA",
                name=name,
                query_type=query_type,
                protocol=protocol,
            )
            return response_wire(local_response(query, dns.rcode.NOERROR), query, tcp=tcp)
        if question.rdtype != dns.rdatatype.A:
            return self.deny(
                query,
                source=source,
                protocol=protocol,
                reason="only A and AAAA queries are supported",
                name=name,
                query_type=query_type,
                rcode=dns.rcode.REFUSED,
                tcp=tcp,
            )

        # Build a fresh query. Nothing else from the guest packet—including
        # mixed-case encoding, EDNS options, additional records, or its message
        # ID—crosses the policy boundary to the caching resolver.
        upstream_query = dns.message.make_query(
            dns.name.from_text(name).canonicalize(),
            dns.rdatatype.A,
            dns.rdataclass.IN,
            use_edns=False,
            want_dnssec=False,
        )
        try:
            upstream_response = await dns.asyncquery.udp(
                upstream_query,
                self.backend_address,
                port=self.backend_port,
                timeout=self.upstream_timeout,
                ignore_unexpected=False,
                ignore_trailing=False,
                raise_on_truncation=False,
                ignore_errors=False,
            )
            if upstream_response.flags & dns.flags.TC:
                upstream_response = await dns.asyncquery.tcp(
                    upstream_query,
                    self.backend_address,
                    port=self.backend_port,
                    timeout=self.upstream_timeout,
                )
        except Exception as error:
            self.audit(
                source=source,
                decision="deny",
                reason=f"upstream resolver failed: {type(error).__name__}",
                name=name,
                query_type=query_type,
                protocol=protocol,
            )
            return response_wire(local_response(query, dns.rcode.SERVFAIL), query, tcp=tcp)

        # Restore only client-facing correlation fields. The recursive answer,
        # including a CNAME chain, is otherwise returned unchanged.
        upstream_response.id = query.id
        upstream_response.question = list(query.question)
        upstream_response.flags = (
            upstream_response.flags & ~dns.flags.RD
        ) | (query.flags & dns.flags.RD)
        upstream_response.use_edns(edns=-1)
        self.audit(
            source=source,
            decision="allow",
            reason="exact A name is allowlisted",
            name=name,
            query_type=query_type,
            protocol=protocol,
        )
        return response_wire(upstream_response, query, tcp=tcp)

    def deny(
        self,
        query: dns.message.Message,
        *,
        source: str,
        protocol: str,
        reason: str,
        rcode: int,
        tcp: bool,
        name: str = "",
        query_type: str = "",
    ) -> bytes:
        self.audit(
            source=source,
            decision="deny",
            reason=reason,
            name=name,
            query_type=query_type,
            protocol=protocol,
        )
        return response_wire(local_response(query, rcode), query, tcp=tcp)


class UDPProtocol(asyncio.DatagramProtocol):
    def __init__(self, server: PolicyServer):
        self.server = server
        self.transport: asyncio.DatagramTransport | None = None

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self.transport = transport  # type: ignore[assignment]

    def datagram_received(self, data: bytes, addr: tuple[str, int]) -> None:
        assert self.transport is not None
        self.server.spawn_udp(self.transport, data, addr)

    def error_received(self, error: Exception) -> None:
        print(f"Seter DNS UDP listener error: {error}", file=sys.stderr, flush=True)


def canonical_policy_name(value: str) -> str:
    text = value.rstrip(".").lower()
    if not text:
        raise ValueError("allowed DNS names must not be empty")
    name = dns.name.from_text(text).canonicalize()
    if not name.is_absolute():
        raise ValueError(f"allowed DNS name is not absolute: {value!r}")
    return name.to_text(omit_final_dot=True)


def canonical_policy_pattern(value: str) -> str:
    text = value.rstrip(".").lower()
    if text.startswith("*."):
        suffix = canonical_policy_name(text[2:])
        if "*" in suffix:
            raise ValueError("wildcard syntax is allowed only in the leading label")
        return "*." + suffix
    if "*" in text:
        raise ValueError("wildcard syntax is allowed only in the leading label")
    return canonical_policy_name(text)


def policy_name_allowed(patterns: frozenset[str], name: str) -> bool:
    if name in patterns:
        return True
    first, separator, suffix = name.partition(".")
    return bool(first) and separator == "." and ("*." + suffix) in patterns


def local_response(query: dns.message.Message, rcode: int) -> dns.message.Message:
    response = dns.message.make_response(query, recursion_available=True)
    response.set_rcode(rcode)
    # Never reflect guest-supplied EDNS options. A plain DNS response is enough
    # for all local denials and the intentionally empty AAAA response.
    response.use_edns(edns=-1)
    return response


def response_wire(
    response: dns.message.Message,
    query: dns.message.Message,
    *,
    tcp: bool,
) -> bytes:
    if tcp:
        return response.to_wire(max_size=65535)
    advertised = query.payload if query.edns >= 0 else 512
    maximum = min(max(advertised, 512), MAX_UDP_RESPONSE_BYTES)
    return response.to_wire(max_size=maximum, prefer_truncation=True)


def error_wire(data: bytes, rcode: int, *, tcp: bool) -> bytes | None:
    if len(data) < 2:
        return None
    query_id = struct.unpack("!H", data[:2])[0]
    request_flags = struct.unpack("!H", data[2:4])[0] if len(data) >= 4 else 0
    response = dns.message.Message(id=query_id)
    response.flags = dns.flags.QR | dns.flags.RA | (request_flags & dns.flags.RD)
    response.set_rcode(rcode)
    return response.to_wire(max_size=65535 if tcp else 512)


def require_string(config: dict[str, Any], key: str) -> str:
    value = config.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"{key} must be a non-empty string")
    return value


def require_string_list(config: dict[str, Any], key: str) -> list[str]:
    value = config.get(key)
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise ValueError(f"{key} must be a list of strings")
    return value


def require_boolean(config: dict[str, Any], key: str) -> bool:
    value = config.get(key)
    if not isinstance(value, bool):
        raise ValueError(f"{key} must be a boolean")
    return value


def require_integer(config: dict[str, Any], key: str, minimum: int, maximum: int) -> int:
    value = config.get(key)
    if not isinstance(value, int) or isinstance(value, bool) or not minimum <= value <= maximum:
        raise ValueError(f"{key} must be an integer from {minimum} through {maximum}")
    return value


def require_number(config: dict[str, Any], key: str, minimum: float, maximum: float) -> float:
    value = config.get(key)
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValueError(f"{key} must be a number")
    result = float(value)
    if not minimum <= result <= maximum:
        raise ValueError(f"{key} must be from {minimum} through {maximum}")
    return result


async def run(args: argparse.Namespace) -> None:
    config = json.loads(Path(args.config).read_text())
    if not isinstance(config, dict):
        raise ValueError("DNS policy must be a JSON object")
    server = PolicyServer(config)
    listen_address = str(ipaddress.IPv4Address(args.listen_address))
    listen_port = int(args.listen_port)

    loop = asyncio.get_running_loop()
    udp_transport, _ = await loop.create_datagram_endpoint(
        lambda: UDPProtocol(server),
        local_addr=(listen_address, listen_port),
        family=socket.AF_INET,
    )
    tcp_server = await asyncio.start_server(
        server.handle_tcp,
        host=listen_address,
        port=listen_port,
        family=socket.AF_INET,
        backlog=server.max_concurrent,
        limit=MAX_TCP_QUERY_BYTES + 2,
    )
    try:
        print(
            f"Seter DNS policy for {server.workspace} listening on "
            f"{listen_address}:{listen_port}",
            flush=True,
        )
        await asyncio.Future()
    finally:
        udp_transport.close()
        tcp_server.close()
        await tcp_server.wait_closed()
        if server.tasks:
            await asyncio.gather(*server.tasks, return_exceptions=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--listen-address", required=True)
    parser.add_argument("--listen-port", required=True, type=int)
    args = parser.parse_args()
    try:
        asyncio.run(run(args))
    except (ValueError, OSError, json.JSONDecodeError) as error:
        print(f"Seter DNS configuration error: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
