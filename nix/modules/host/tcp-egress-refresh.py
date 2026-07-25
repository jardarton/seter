#!/usr/bin/env python3
"""Atomically refresh one workspace's direct-TCP nftables destination set."""

import argparse
import ipaddress
import json
import subprocess
import sys
from pathlib import Path


def ipv4_literal(value: str):
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return None
    return address if address.version == 4 else None


def resolved_addresses(dig: str, host: str, upstream_servers: list[str]):
    servers = upstream_servers or [None]
    addresses = set()
    for server in servers:
        command = [dig, "+short", "+time=2", "+tries=1"]
        if server is not None:
            command.append(f"@{server}")
        command.extend([host, "A"])
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode not in (0, 9):
            print(f"seter TCP egress: DNS lookup for {host} failed: {result.stderr.strip()}", file=sys.stderr)
            continue
        for line in result.stdout.splitlines():
            address = ipv4_literal(line.strip())
            if address is not None:
                addresses.add(address)
    return addresses


def nft_script(table: str, set_name: str, elements: set[tuple[str, int]]):
    lines = [f"flush set inet {table} {set_name}"]
    if elements:
        rendered = ", ".join(f"{address} . {port}" for address, port in sorted(elements))
        lines.append(f"add element inet {table} {set_name} {{ {rendered} }}")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--dig", required=True)
    parser.add_argument("--nft", required=True)
    parser.add_argument("--set", required=True, dest="set_name")
    parser.add_argument("--table", default="seter_l3")
    parser.add_argument("--flush", action="store_true")
    args = parser.parse_args()

    config = json.loads(Path(args.config).read_text())
    elements: set[tuple[str, int]] = set()

    if not args.flush:
        for destination in config["destinations"]:
            host = destination["host"].lower()
            literal = ipv4_literal(host)
            addresses = (
                {literal}
                if literal is not None
                else resolved_addresses(args.dig, host, config["upstreamServers"])
            )
            for address in addresses:
                # A literal address is an explicit authorization. Never trust
                # a DNS name that resolves to special-use/private space: that
                # would let an allowed public name rebind onto host-local,
                # link-local, or private infrastructure. Configure a literal
                # IPv4 address when such access is deliberately required.
                if literal is None and (not address.is_global or address.is_multicast):
                    print(
                        f"seter TCP egress: ignored non-global answer {address} for {host}",
                        file=sys.stderr,
                    )
                    continue
                elements.add((str(address), destination["port"]))

    result = subprocess.run(
        [args.nft, "-f", "-"],
        input=nft_script(args.table, args.set_name, elements),
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
