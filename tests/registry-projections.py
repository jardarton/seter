"""Check generated registry/policy contracts, including absence of secret paths.

Arguments: alpha/beta registry, identity registry, identity Runner, DNS policy,
credential-bearing proxy policy. All inputs must be the synthetic check fixtures.
"""

import json
from pathlib import Path
import sys

registry, identity_registry, runner, dns, proxy = sys.argv[1:]
registry = json.loads(Path(registry).read_text())
assert registry["version"] == 8
assert sorted(registry["workspaces"]) == ["alpha", "beta"]
alpha = registry["workspaces"]["alpha"]
assert alpha["hostname"] == "alpha.vm"
assert alpha["network"]["address"] == "10.100.0.10"
assert alpha["network"]["mac"] == "02:00:00:00:00:10"
assert alpha["resources"] == {"memoryMiB": 4096, "vcpu": 2, "cpuQuotaPercent": 200}
assert alpha["ssh"] == {"user": "seter"}
assert alpha["guestProfile"] == "default"
assert alpha["repositories"]["workspace"]["url"] == "https://example.invalid/owner/workspace.git"
assert alpha["repositories"]["workspace"]["checkoutName"] == "workspace"
assert alpha["runner"]["path"].startswith("/nix/store/")
assert alpha["storage"] == {
    "project": {"image": "alpha-project.img", "sizeMiB": 4096},
    "home": {"image": "alpha-home.img", "sizeMiB": 4096},
    "nixStore": {"image": "alpha-nix-store.img", "sizeMiB": 16384},
}
assert not {"egress", "secrets", "hostServices"} & alpha.keys()

identity_registry = json.loads(Path(identity_registry).read_text())
assert identity_registry["version"] == 8
identity = identity_registry["workspaces"]["identity"]
assert identity["repositories"]["workspace"] == {
    "local": False,
    "url": "https://api.example.com/owner/workspace.git", "branch": None,
    "checkoutName": "workspace", "credential": {
        "name": "githubToken", "placeholder": "seter-placeholder-github-0123456789abcdef",
    },
}
manifest = Path(runner) / "share/seter/identity.json"
assert manifest.is_file() and not manifest.is_symlink()
manifest_text = manifest.read_text()
assert "/run/secrets/identity-github-token" not in manifest_text
# Compare the complete deployed manifest, rather than sampling individual fields.
assert json.loads(manifest_text) == identity["runner"]["identity"]
assert identity["runner"]["identity"] == {
    "version": 3, "workspace": "identity", "hostname": "identity.vm",
    "network": {
        "address": "10.100.0.12", "gateway": "10.100.0.1", "mac": "02:00:00:00:00:12",
        "prefixLength": 24, "tap": "seter-identity",
    },
    "proxy": {"url": "http://10.100.0.1:18081"}, "ssh": {"user": "seter"},
    "guestProfile": "terminal", "developmentPorts": [3000],
    "resources": {"memoryMiB": 4096, "vcpu": 2},
    "storage": {
        "project": {"image": "identity-project.img", "sizeMiB": 4096},
        "home": {"image": "identity-home.img", "sizeMiB": 4096},
        "nixStore": {"image": "identity-nix-store.img", "sizeMiB": 16384},
    },
}
assert identity["runner"]["path"] == runner

expected_dns = {
    "version": 1, "workspace": "alpha", "sourceAddress": "10.100.0.10",
    "allowedNames": ["example.invalid"], "backendAddress": "127.0.0.1", "backendPort": 15353,
}
dns = json.loads(Path(dns).read_text())
assert {key: dns[key] for key in expected_dns} == expected_dns
proxy_text = Path(proxy).read_text()
assert "/run/secrets/github-token" not in proxy_text
proxy = json.loads(proxy_text)
assert proxy["version"] == 4
alpha = proxy["workspaces"]["10.100.0.10"]
assert alpha["name"] == "alpha"
assert alpha["httpHosts"] == ["example.invalid", "api.example.com"]
assert alpha["passthroughHosts"] == []
assert alpha["repositories"]["workspace"] == {
    "host": "example.invalid", "path": "/owner/workspace.git", "credential": None,
}
assert alpha["secrets"] == {"githubToken": {
    "credential": "seter-alpha.githubToken", "repositoryOnly": False,
    "placeholder": "seter-placeholder-0123456789abcdef", "hosts": ["api.example.com"],
    "headers": ["authorization", "x-api-key"],
}}
assert proxy["workspaces"]["10.100.0.11"]["secrets"] == {}
print("Registry, Runner manifest and policy projection contracts passed")
