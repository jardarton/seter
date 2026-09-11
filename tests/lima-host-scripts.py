"""Exercise generated Lima helpers with synthetic cidata and mocked mounts.

No root access, live keys, Lima instance, or real mount is used. The parser and
validation code come from the actual generated scripts; only fixed filesystem
locations and privileged mount commands are redirected into a temporary tree.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


BOOTSTRAP, EXCHANGE = (Path(arg).read_text() for arg in sys.argv[1:])
sys.argv = sys.argv[:1]

VALID_PUBLIC_KEY = (
    "ssh-ed25519 "
    "AAAAC3NzaC1lZDI1NTE5AAAAIL6bkIjI/PJbREqh9xdy+dmsFWFbwQtmo/JuHxbCOJUf "
    "synthetic-lima-helper-key"
)

MOUNT_TOOL = r'''
import json
import os
from pathlib import Path
import sys

state_file = Path(os.environ["MOUNT_STATE"])
state = json.loads(state_file.read_text())
tool = Path(sys.argv[0]).name
if tool == "mountpoint":
    sys.exit(0 if state["mounted"] else 1)
elif tool == "mount":
    assert sys.argv[1:5] == ["-t", "virtiofs", "-o", "rw"]
    state.update(mounted=True, SOURCE=sys.argv[5], FSTYPE="virtiofs")
    state["OPTIONS"] = state.get("result_options", "rw,relatime")
    state_file.write_text(json.dumps(state))
elif tool == "findmnt":
    print(state[sys.argv[sys.argv.index("-o") + 1]])
else:
    raise AssertionError(tool)
'''


class LimaHelpers(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cidata = self.root / "cidata"
        self.cidata.mkdir()
        (self.cidata / "lima.env").write_text('LIMA_CIDATA_USER="operator"\n')
        (self.cidata / "user-data").write_text(
            'users:\n- name: operator\n  ssh-authorized-keys:\n'
            f'    - "{VALID_PUBLIC_KEY}"\nmounts:\n'
            '- [lima-example, /workspace/seter-exchange, virtiofs, "rw"]\n'
        )
        self.state = self.root / "mount-state.json"
        self.state.write_text(json.dumps({"mounted": False}))
        self.env = dict(os.environ, MOUNT_STATE=str(self.state))
        for tool in ("mount", "mountpoint", "findmnt"):
            path = self.root / tool
            path.write_text(f"#!{sys.executable}\n" + MOUNT_TOOL)
            path.chmod(0o755)

    def run_helper(self, source, succeeds=True):
        # Preserve the cidata mount selector; redirect only the target variable.
        script = source.replace("cidata=/mnt/lima-cidata", f"cidata={self.cidata}")
        script = script.replace("/run/seter-lima-ssh", str(self.root / "keys"))
        script = script.replace(
            "mountPoint=/workspace/seter-exchange",
            f"mountPoint={self.root / 'exchange'}",
        )
        script = re.sub(
            r"/nix/store/[^/]+/bin/(mountpoint|findmnt|mount)\b",
            lambda match: str(self.root / match[1]),
            script,
        )
        path = self.root / "helper"
        path.write_text(script)
        path.chmod(0o755)
        result = subprocess.run([str(path)], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, succeeds, result.stderr)

    def test_bootstrap_key_projection(self):
        self.run_helper(BOOTSTRAP)
        key = self.root / "keys/operator"
        self.assertEqual(key.read_text(), f"{VALID_PUBLIC_KEY}\n")
        self.assertEqual(key.stat().st_mode & 0o777, 0o444)
        self.assertEqual(key.parent.stat().st_mode & 0o777, 0o755)
        self.run_helper(BOOTSTRAP)  # repeat activation

    def test_bootstrap_rejects_invalid_user(self):
        (self.cidata / "lima.env").write_text('LIMA_CIDATA_USER="../escape"\n')
        self.run_helper(BOOTSTRAP, succeeds=False)
        self.assertFalse((self.root / "escape").exists())

    def test_bootstrap_rejects_absent_keys(self):
        (self.cidata / "user-data").write_text("users: []\n")
        self.run_helper(BOOTSTRAP, succeeds=False)

    def test_failed_bootstrap_preserves_existing_key(self):
        self.run_helper(BOOTSTRAP)
        (self.cidata / "user-data").write_text("users: []\n")
        self.run_helper(BOOTSTRAP, succeeds=False)
        self.assertEqual((self.root / "keys/operator").read_text(), f"{VALID_PUBLIC_KEY}\n")
        self.assertEqual(list((self.root / "keys").iterdir()), [self.root / "keys/operator"])

    def test_malformed_bootstrap_preserves_existing_key(self):
        self.run_helper(BOOTSTRAP)
        for projected_key in ("synthetic-public-key", ""):
            with self.subTest(projected_key=projected_key):
                (self.cidata / "user-data").write_text(
                    "users:\n- name: operator\n  ssh-authorized-keys:\n"
                    f'    - "{projected_key}"\n'
                )
                self.run_helper(BOOTSTRAP, succeeds=False)
                self.assertEqual(
                    (self.root / "keys/operator").read_text(),
                    f"{VALID_PUBLIC_KEY}\n",
                )
                self.assertEqual(
                    list((self.root / "keys").iterdir()),
                    [self.root / "keys/operator"],
                )

    def test_mount_and_repeat(self):
        self.run_helper(EXCHANGE)
        state = json.loads(self.state.read_text())
        self.assertEqual(state["SOURCE"], "lima-example")
        self.assertEqual(state["OPTIONS"], "rw,relatime")
        self.run_helper(EXCHANGE)

    def test_mount_rejects_missing_or_invalid_tag(self):
        for tag in (None, "../bad", "bad;command"):
            with self.subTest(tag=tag):
                data = "mounts: []\n" if tag is None else (
                    f'- [{tag}, /workspace/seter-exchange, virtiofs, "rw"]\n'
                )
                (self.cidata / "user-data").write_text(data)
                self.run_helper(EXCHANGE, succeeds=False)

    def test_mount_rejects_existing_wrong_source_type_or_mode(self):
        for field, value in (
            ("SOURCE", "other-share"), ("FSTYPE", "tmpfs"), ("OPTIONS", "ro,relatime")
        ):
            with self.subTest(field=field):
                state = dict(mounted=True, SOURCE="lima-example", FSTYPE="virtiofs",
                             OPTIONS="rw,relatime")
                state[field] = value
                self.state.write_text(json.dumps(state))
                self.run_helper(EXCHANGE, succeeds=False)
                self.assertEqual(json.loads(self.state.read_text()), state)

    def test_mount_rejects_read_only_result(self):
        self.state.write_text(json.dumps(dict(mounted=False, result_options="ro")))
        self.run_helper(EXCHANGE, succeeds=False)


unittest.main()
