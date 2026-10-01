"""Exercise registry queries, stale Runner rejection and reviewed policy writes.

Run as a non-root user. Arguments: Seter binary, alpha/beta registry, identity
registry and identity's desired Policy File, from the synthetic check fixtures.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib

binary, registry, identity_registry, policy_file = sys.argv[1:]
binary = str(Path(binary).resolve())
assert os.geteuid() != 0, "run this test as a non-root user"

with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("SETER_")}
    environment["SETER_REGISTRY"] = registry

    def run(*arguments, overrides=None, answers=None):
        return subprocess.run([binary, *arguments], env=environment | (overrides or {}),
                              text=True, input=answers, capture_output=True, check=False)

    result = run("list")
    assert result.returncode == 0 and result.stdout == "alpha\nbeta\n", result
    result = run("ip", "alpha")
    assert result.returncode == 0 and result.stdout == "10.100.0.10\n", result

    # Caller-side registry fields can agree internally and still disagree with
    # the deployed Runner. Reject it before starting any service.
    changed = json.loads(Path(identity_registry).read_text())
    changed["workspaces"]["identity"]["network"]["address"] = "10.100.0.13"
    changed["workspaces"]["identity"]["runner"]["identity"]["network"]["address"] = "10.100.0.13"
    changed_registry = directory / "changed-registry.json"
    changed_registry.write_text(json.dumps(changed))
    calls = directory / "systemctl-calls.json"
    systemctl = directory / "systemctl"
    systemctl.write_text(f'''#!{sys.executable}
import json
from pathlib import Path
import sys
assert sys.argv[1] == "show", sys.argv
Path({str(calls)!r}).write_text(json.dumps(sys.argv[1:]))
print("ActiveState=inactive\\nSubState=dead\\nMainPID=0")
''')
    systemctl.chmod(0o755)
    result = run("up", "identity", overrides={
        "SETER_REGISTRY": str(changed_registry), "SETER_SYSTEMCTL": str(systemctl),
        "SETER_STATE_DIR": str(directory / "state"), "SETER_TEST_MODE": "1",
    })
    assert result.returncode == 1, result
    assert 'runner identity does not match workspace "identity"' in result.stderr, result
    assert json.loads(calls.read_text())[0:2] == ["show", "seter-vm-identity.service"]

    sudo = directory / "audit-sudo"
    records = [
        {"timestampMicros": 1, "boundary": "http", "decision": "deny",
         "destination": "new.example.com", "method": "GET", "protocol": None,
         "reason": "host is denied", "path": "/private?query=hidden", "port": None},
        {"timestampMicros": 2, "boundary": "dns", "decision": "deny",
         "destination": "ambiguous.example.net", "method": None, "protocol": "udp",
         "reason": "name is denied", "path": None, "port": None},
    ]
    sudo.write_text(f'''#!{sys.executable}
import json
import sys
assert sys.argv[1:] == ["--", {binary!r}, "__audit", "identity"], sys.argv
for record in {records!r}:
    print(json.dumps(record))
''')
    sudo.chmod(0o755)
    original = "# retained comment\n" + Path(policy_file).read_text()
    policy = directory / "review-policy.toml"
    for confirmation in ["n", "y"]:
        policy.write_text(original)
        result = run("policy", "review", "identity", "--file", str(policy),
                     overrides={"SETER_REGISTRY": identity_registry, "SETER_SUDO": str(sudo)},
                     answers=f"y\nh\nn\n{confirmation}\n")
        assert result.returncode == 0, result
        assert "Write this exact diff?" in result.stdout, result
        if confirmation == "n":
            assert policy.read_bytes() == original.encode(), "declined review wrote the Policy File"
        else:
            text = policy.read_text()
            assert "# retained comment" in text
            assert "private?query=hidden" not in text
            assert tomllib.loads(text) == {"version": 1, "workspaces": {"identity": {
                "egress": {"http-hosts": [
                    "ambiguous.example.net", "api.example.com", "new.example.com",
                ]},
            }}}, text

print("CLI queries, stale Runner rejection and confirmed/declined policy review passed")
