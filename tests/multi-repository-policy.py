"""Synthetic tests of the real proxy parser and credential rewrite boundary."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from mitmproxy import http
from mitmproxy.exceptions import OptionsError

spec = importlib.util.spec_from_file_location("seter_policy", sys.argv.pop(1))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RepositoryPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.policy_path = self.directory / "policy.json"
        self.ready = self.directory / "ready"
        self.workspace = {
            "name": "product",
            "httpHosts": ["git.example", "second.example"],
            "passthroughHosts": [],
            "repositories": {
                "frontend": {"host": "git.example", "path": "/team/frontend.git", "credential": "frontend"},
                "backend": {"host": "git.example", "path": "/team/backend.git", "credential": "backend"},
                "shared": {"host": "second.example", "path": "/team/shared.git", "credential": "backend"},
            },
            "secrets": {},
        }
        for name in ("frontend", "backend"):
            (self.directory / name).write_text(f"Bearer synthetic-{name}-credential")
            self.workspace["secrets"][name] = {
                "credential": name,
                "placeholder": f"seter-placeholder-{name}-0123456789abcdef",
                "hosts": ["git.example", "second.example"],
                "headers": ["authorization"],
                "repositoryOnly": True,
            }

    def load(self, workspace=None):
        self.policy_path.write_text(json.dumps({
            "version": 4, "workspaces": {"10.100.0.10": workspace or self.workspace}
        }))
        policy = module.SeterPolicy()
        options = SimpleNamespace(seter_policy=str(self.policy_path), seter_ready_file=str(self.ready))
        with patch.object(module.ctx, "options", options, create=True), patch.dict(os.environ, CREDENTIALS_DIRECTORY=str(self.directory)):
            policy.configure({"seter_policy"})
        self.assertTrue(self.ready.exists())
        return policy.workspaces["10.100.0.10"]

    def inject(self, workspace, credential, host, path, scheme="https"):
        placeholder = self.workspace["secrets"][credential]["placeholder"]
        request = http.Request.make("GET", f"{scheme}://{host}{path}", headers={"Authorization": placeholder})
        flow = SimpleNamespace(request=request)
        names, error = module.SeterPolicy._inject_request_secrets(flow, workspace, host, scheme, path)
        if error:
            self.assertEqual(request.headers["Authorization"], placeholder)
        else:
            self.assertEqual(names, [credential])
            self.assertEqual(request.headers["Authorization"], f"Bearer synthetic-{credential}-credential")
        return error

    def test_exact_paths_shared_binding_and_other_hosts(self):
        workspace = self.load()
        for suffix in ("", "/info/refs?service=git-upload-pack", "/git-upload-pack", "/git-receive-pack"):
            self.assertIsNone(self.inject(workspace, "frontend", "git.example", "/team/frontend.git" + suffix))
            self.assertIsNone(self.inject(workspace, "backend", "git.example", "/team/backend.git" + suffix))
            self.assertIsNone(self.inject(workspace, "backend", "second.example", "/team/shared.git" + suffix))
        for host, path in (
            ("git.example", "/team/backend.git/info/refs"),
            ("second.example", "/team/frontend.git/info/refs"),
            ("git.example", "/team/frontend.git/../backend.git/info/refs"),
            ("git.example", "/team/frontend.git/%2e%2e/backend.git/info/refs"),
            ("git.example", "/team/frontend.git.evil/info/refs"),
            ("git.example", "/team/frontend.git/arbitrary"),
        ):
            self.assertIsNotNone(self.inject(workspace, "frontend", host, path))
        self.assertIsNotNone(self.inject(workspace, "backend", "git.example", "/team/frontend.git/info/refs"))
        self.assertIsNotNone(self.inject(workspace, "frontend", "git.example", "/team/frontend.git/info/refs", "http"))

    def test_removed_association_never_becomes_host_wide(self):
        del self.workspace["repositories"]["frontend"]
        workspace = self.load()
        self.assertIsNotNone(self.inject(workspace, "frontend", "git.example", "/team/frontend.git/info/refs"))
        self.assertIsNotNone(self.inject(workspace, "frontend", "git.example", "/api"))
        self.assertIsNone(self.inject(workspace, "backend", "git.example", "/team/backend.git/info/refs"))

    def test_invalid_collections_fail_without_readiness(self):
        for repositories in ({}, [], {"bad": None}, {"../bad": self.workspace["repositories"]["frontend"]}):
            candidate = copy.deepcopy(self.workspace)
            candidate["repositories"] = repositories
            with self.assertRaises(OptionsError):
                self.load(candidate)
            self.assertFalse(self.ready.exists())
        for field, value in (("path", "/team/../bad"), ("credential", "missing"), ("host", "unapproved.example")):
            candidate = copy.deepcopy(self.workspace)
            candidate["repositories"]["backend"][field] = value
            with self.assertRaises(OptionsError):
                self.load(candidate)
            self.assertFalse(self.ready.exists())


unittest.main()
