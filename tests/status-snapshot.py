"""Verify consistent status output when systemd changes between queries.

Run with a Seter binary and the synthetic alpha/beta registry fixture.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary, registry = sys.argv[1:]

with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    counts = directory / "queries.json"
    systemctl = directory / "systemctl"
    systemctl.write_text(f'''#!{sys.executable}
import json
import os
from pathlib import Path
import sys

assert sys.argv[1] == "show", sys.argv
assert sys.argv[3:] == ["--property=ActiveState", "--property=SubState", "--property=MainPID", "--no-pager"], sys.argv
unit = sys.argv[2]
assert unit in ["seter-vm-alpha.service", "seter-vm-beta.service"], unit
counts = Path(os.environ["SETER_STATUS_TEST_COUNTS"])
queries = json.loads(counts.read_text()) if counts.exists() else {{}}
queries[unit] = queries.get(unit, 0) + 1
counts.write_text(json.dumps(queries))
if queries[unit] == 1:
    pid = 123 if unit == "seter-vm-alpha.service" else 456
    print(f"ActiveState=active\\nSubState=running\\nMainPID={{pid}}")
else:
    print("ActiveState=inactive\\nSubState=dead\\nMainPID=0")
''')
    systemctl.chmod(0o755)
    environment = dict(os.environ, SETER_REGISTRY=registry,
                       SETER_SYSTEMCTL=str(systemctl), SETER_STATUS_TEST_COUNTS=str(counts))

    def status(*arguments):
        result = subprocess.run([binary, "status", *arguments], env=environment,
                                text=True, capture_output=True, check=False)
        assert not result.stderr, result.stderr
        return result

    # Detailed output and exit status must describe the first snapshot. The
    # next command observes the transition, without mixing the two snapshots.
    running = status("alpha")
    assert running.returncode == 0, running
    assert running.stdout.splitlines() == [
        "name:  alpha", "state: running", "ip:    10.100.0.10",
        "pid:   123", "unit:  active/running",
    ], running.stdout
    assert json.loads(counts.read_text()) == {"seter-vm-alpha.service": 1}
    stopped = status("alpha")
    assert stopped.returncode == 3, stopped
    assert stopped.stdout.splitlines() == [
        "name:  alpha", "state: stopped", "ip:    10.100.0.10", "pid:   -",
    ], stopped.stdout
    assert json.loads(counts.read_text()) == {"seter-vm-alpha.service": 2}

    # The table must use one query per workspace as well.
    counts.unlink()
    running = status()
    assert running.returncode == 0, running
    assert [line.split() for line in running.stdout.splitlines()] == [
        ["NAME", "STATE", "IP", "PID"],
        ["alpha", "running", "10.100.0.10", "123"],
        ["beta", "running", "10.100.0.11", "456"],
    ], running.stdout
    assert json.loads(counts.read_text()) == {
        "seter-vm-alpha.service": 1, "seter-vm-beta.service": 1,
    }
    stopped = status()
    assert stopped.returncode == 0, stopped
    assert [line.split() for line in stopped.stdout.splitlines()][1:] == [
        ["alpha", "stopped", "10.100.0.10", "-"],
        ["beta", "stopped", "10.100.0.11", "-"],
    ], stopped.stdout
    assert json.loads(counts.read_text()) == {
        "seter-vm-alpha.service": 2, "seter-vm-beta.service": 2,
    }

print("Status snapshot regression passed for detailed and table output")
