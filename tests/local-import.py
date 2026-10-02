"""Verify Git-bundle import, preserved branches, and non-destructive failures."""
from pathlib import Path
import subprocess
import sys
import tempfile

script = Path(sys.argv[1]).read_text()

def git(directory, *arguments):
    return subprocess.run(["git", "-C", str(directory), *arguments],
                          check=True, capture_output=True, text=True).stdout.strip()

with tempfile.TemporaryDirectory() as root:
    root = Path(root)
    source = root / "source"
    source.mkdir()
    git(source, "init", "--initial-branch=main")
    git(source, "config", "user.name", "Synthetic Author")
    git(source, "config", "user.email", "author@example.invalid")
    (source / "file").write_text("initial\n")
    git(source, "add", "file")
    git(source, "commit", "-m", "initial")
    initial = git(source, "rev-parse", "HEAD")
    git(source, "branch", "worker")
    git(source, "tag", "baseline")
    bundle = root / "source.bundle"
    git(source, "bundle", "create", str(bundle), "--all")

    def invoke(target, payload=b"", mode="import", branch=""):
        return subprocess.run(["sh", "-c", script, "seter-test", str(target), branch, mode],
                              input=payload, capture_output=True)

    target = root / "checkout"
    result = invoke(target, bundle.read_bytes())
    assert result.returncode == 0, result.stderr
    assert git(target, "rev-parse", "worker") == initial
    assert git(target, "rev-parse", "baseline") == initial
    assert git(target, "remote") == ""
    assert git(target, "config", "--local", "--get", "seter.localImport") == "true"
    (target / "file").write_text("dirty\n")
    result = invoke(target, mode="check")
    assert result.returncode == 0, result.stderr
    result = invoke(target, bundle.read_bytes())
    assert result.returncode != 0
    assert (target / "file").read_text() == "dirty\n"

    link = root / "link"
    link.symlink_to(target, target_is_directory=True)
    assert invoke(link, bundle.read_bytes()).returncode != 0
    occupied = root / "occupied"
    occupied.mkdir()
    (occupied / "keep").write_text("retained")
    assert invoke(occupied, bundle.read_bytes()).returncode != 0
    assert (occupied / "keep").read_text() == "retained"
    invalid = root / "invalid"
    assert invoke(invalid, b"not a Git bundle").returncode != 0
    assert not invalid.exists()
    assert not list(root.glob(".seter-import-*"))

    git(source, "checkout", "worker")
    (source / "file").write_text("worker\n")
    git(source, "commit", "-am", "worker")
    worker = git(source, "rev-parse", "HEAD")
    partial = root / "partial.bundle"
    git(source, "bundle", "create", str(partial), "worker", "^main")
    assert invoke(root / "partial", partial.read_bytes()).returncode != 0
    git(source, "bundle", "create", str(bundle), "--all")
    selected = root / "selected"
    result = invoke(selected, bundle.read_bytes(), branch="main")
    assert result.returncode == 0, result.stderr
    assert git(selected, "rev-parse", "HEAD") == initial
    assert git(selected, "rev-parse", "worker") == worker
    assert not list(root.glob(".seter-import-*"))

print("Local bundle import preserves branches and working data; invalid imports leave no checkout")
