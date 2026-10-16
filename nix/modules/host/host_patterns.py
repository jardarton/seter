"""Host Pattern contract shared by Seter's DNS and proxy policy boundaries."""

import ipaddress
import re
from pathlib import Path

_LABEL = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
_DNS_NAME = re.compile(rf"{_LABEL}(?:\.{_LABEL})+")
_PUBLIC_SUFFIX_RULES = frozenset(
    line.strip()
    for line in Path(__file__).with_name("public_suffix_list.dat").read_text().splitlines()
    if line.strip() and not line.strip().startswith("//")
)


def canonical_host(value: str) -> str:
    if not isinstance(value, str) or not value.isascii():
        raise ValueError("host must be an ASCII string")
    host = value.lower()
    if len(host) > 253 or _DNS_NAME.fullmatch(host) is None:
        raise ValueError("host must be an ASCII multi-label DNS name of at most 253 characters")
    if re.fullmatch(r"[0-9.]+", host):
        # Numeric names must be unambiguous canonical dotted-decimal IPv4.
        ipaddress.IPv4Address(host)
    return host


def exact_valid(value: str) -> bool:
    try:
        canonical_host(value)
        return True
    except ValueError:
        return False


def wildcard_suffix_forbidden(suffix: str) -> bool:
    labels = suffix.split(".")
    return (
        len(labels) < 2
        or any(label.startswith("xn--") for label in labels)
        or (
            "!" + suffix not in _PUBLIC_SUFFIX_RULES
            and (
                suffix in _PUBLIC_SUFFIX_RULES
                or "*." + suffix in _PUBLIC_SUFFIX_RULES
                or "*." + ".".join(labels[1:]) in _PUBLIC_SUFFIX_RULES
            )
        )
    )


def canonical_pattern(value: str) -> str:
    if not isinstance(value, str) or not value.isascii():
        raise ValueError("Host Pattern must be an ASCII string")
    pattern = value.lower()
    if not pattern.startswith("*."):
        return canonical_host(pattern)
    suffix = canonical_host(pattern[2:])
    if (
        len(pattern) > 253
        or re.fullmatch(r"[0-9.]+", suffix)
        or wildcard_suffix_forbidden(suffix)
    ):
        raise ValueError("wildcard must name a safe DNS suffix within the hostname length limit")
    return "*." + suffix


def request_host(value: object) -> str:
    """Canonicalize an HTTP/TLS name, permitting one DNS root dot."""
    try:
        return canonical_host(value.removesuffix(".") if isinstance(value, str) else value)
    except ValueError:
        return ""


def pattern_matches(pattern: str, host: str) -> bool:
    if not exact_valid(host):
        return False
    host = host.lower()
    pattern = pattern.lower()
    if pattern == host:
        return True
    if not pattern.startswith("*."):
        return False
    first, separator, suffix = host.partition(".")
    return bool(first) and separator == "." and suffix == pattern[2:]


def patterns_overlap(left: str, right: str) -> bool:
    return left.lower() == right.lower() or pattern_matches(left, right) or pattern_matches(right, left)


def host_allowed(patterns: frozenset[str], host: str) -> bool:
    return any(pattern_matches(pattern, host) for pattern in patterns)


# Mirrors the Nix and Rust Policy File validation of private-http grants.
_PRIVATE_UPSTREAM_NETWORKS = tuple(
    ipaddress.IPv4Network(network)
    for network in ("10.0.0.0/8", "100.64.0.0/10", "172.16.0.0/12", "192.168.0.0/16")
)


def private_upstream(host: object, address: object) -> tuple[str, str]:
    """Validate one Private HTTPS Upstream and return its canonical form."""
    if not isinstance(address, str) or not exact_valid(host) or re.fullmatch(r"[0-9.]+", host):
        raise ValueError(f"invalid private HTTPS upstream {host!r}")
    try:
        parsed = ipaddress.IPv4Address(address)
    except ValueError as error:
        raise ValueError(f"invalid private HTTPS upstream {host!r}") from error
    if str(parsed) != address or not any(parsed in network for network in _PRIVATE_UPSTREAM_NETWORKS):
        raise ValueError(f"invalid private HTTPS upstream {host!r}")
    return canonical_host(host), address
