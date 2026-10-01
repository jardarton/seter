"""Exercise CLI delegation and the unprivileged lifecycle test boundary.

Run as a non-root user with a Seter binary and the synthetic alpha/beta registry.
Root-owned configuration and real sudo authorization are covered by host-runtime.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary, registry = sys.argv[1:]
binary = str(Path(binary).resolve())
assert os.geteuid() != 0, "run this test as a non-root user"

with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    calls = directory / "calls.json"
    sudo = directory / "sudo"
    sudo.write_text(f'''#!{sys.executable}
import json
import os
from pathlib import Path
import sys
import time

assert sys.argv[1] == "--", sys.argv
assert sys.argv[2] == {binary!r}, sys.argv
arguments = sys.argv[3:]
Path({str(calls)!r}).write_text(json.dumps(arguments))
assert arguments in [["__stop", "alpha"], ["__audit", "alpha"]], arguments
print("helper diagnostic", file=sys.stderr)
if os.environ.get("SETER_PRIVILEGE_TEST_FAIL"):
    sys.exit(7)
if arguments[0] == "__audit":
    for _ in range(2):
        print(json.dumps(dict(timestampMicros=time.time_ns() // 1000,
                             boundary="http", decision="deny",
                             destination="example.invalid", port=80,
                             protocol=None, method="GET", reason="test denial",
                             path=None)), flush=True)
else:
    print("delegated stop")
''')
    sudo.chmod(0o755)
    systemctl = directory / "systemctl"
    systemctl.write_text(f'''#!{sys.executable}
import sys
if sys.argv[1] == "show":
    print("ActiveState=inactive\\nSubState=dead\\nMainPID=0")
else:
    assert sys.argv[1:] == ["stop", "seter-runtime-alpha.target"], sys.argv
''')
    systemctl.chmod(0o755)
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("SETER_")}
    environment.update(SETER_REGISTRY=registry, SETER_SUDO=str(sudo),
                       SETER_SYSTEMCTL=str(systemctl))

    def run(*arguments, overrides=None):
        return subprocess.run([binary, *arguments],
                              env=environment | (overrides or {}), text=True,
                              capture_output=True, check=False)

    for arguments, helper in [(('down', 'alpha'), '__stop'),
                              (('audit', 'alpha'), '__audit')]:
        result = run(*arguments)
        assert result.returncode == 0, result
        assert json.loads(calls.read_text()) == [helper, "alpha"]
        assert "helper diagnostic" in result.stderr, result
        if helper == "__audit":
            assert "2 deny" in result.stdout, result
            assert "example.invalid:80 GET" in result.stdout, result
        else:
            assert result.stdout == "delegated stop\n", result

        # Validation catches unknown workspaces before invoking sudo.
        calls.unlink()
        result = run(arguments[0], "missing")
        assert result.returncode == 1 and "is not configured" in result.stderr, result
        assert not calls.exists()

        # A failed helper must fail the outer command too.
        result = run(*arguments, overrides={"SETER_PRIVILEGE_TEST_FAIL": "1"})
        assert result.returncode == 1, result
        assert "helper" in result.stderr and "failed" in result.stderr, result

    test_state = {"SETER_STATE_DIR": str(directory / "state"), "SETER_TEST_MODE": "1"}
    for overrides in [{}, {"SETER_STATE_DIR": test_state["SETER_STATE_DIR"]},
                      {"SETER_TEST_MODE": "1"}]:
        result = run("__stop", "alpha", overrides=overrides)
        assert result.returncode == 1 and "must run as root" in result.stderr, result

    calls.unlink()
    result = run("down", "alpha", overrides=test_state)
    assert result.returncode == 0 and "already stopped" in result.stdout, result
    assert not calls.exists(), "explicit test state should bypass sudo for lifecycle"

    # Audit must never inherit lifecycle's test bypass.
    result = run("__audit", "alpha", overrides=test_state)
    assert result.returncode == 1 and "must run as root" in result.stderr, result

print("Privilege regression passed for delegation, helper failures and test boundaries")
