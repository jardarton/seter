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
            "privateHttpHosts": {},
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
            "version": 5, "workspaces": {"10.100.0.10": workspace or self.workspace}
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
        self.assertEqual(workspace["secrets"]["frontend"]["repositoryScope"], frozenset())
        self.assertIsNotNone(self.inject(workspace, "frontend", "git.example", "/team/frontend.git/info/refs"))
        self.assertIsNotNone(self.inject(workspace, "frontend", "git.example", "/api"))
        self.assertIsNone(self.inject(workspace, "backend", "git.example", "/team/backend.git/info/refs"))

    def test_compiles_shared_scopes(self):
        workspace = self.load()
        expected = frozenset(
            (host, path + suffix)
            for host, path in (
                ("git.example", "/team/backend.git"),
                ("second.example", "/team/shared.git"),
            )
            for suffix in ("", "/info/refs", "/git-upload-pack", "/git-receive-pack")
        )
        self.assertEqual(workspace["secrets"]["backend"]["repositoryScope"], expected)
        self.assertNotIn("repositories", workspace)
        self.assertIsNotNone(self.inject(workspace, "backend", "git.example", "/api"))

    def test_repository_binding_requires_repository_only(self):
        for flag in (False, None):
            candidate = copy.deepcopy(self.workspace)
            if flag is None:
                del candidate["secrets"]["backend"]["repositoryOnly"]
            else:
                candidate["secrets"]["backend"]["repositoryOnly"] = flag
            with self.assertRaises(OptionsError):
                self.load(candidate)
            self.assertFalse(self.ready.exists())

    def test_generic_secret_retains_host_and_https_restrictions(self):
        del self.workspace["repositories"]["frontend"]
        self.workspace["secrets"]["frontend"]["repositoryOnly"] = False
        workspace = self.load()
        self.assertIsNone(workspace["secrets"]["frontend"]["repositoryScope"])
        self.assertIsNone(self.inject(workspace, "frontend", "git.example", "/api"))
        self.assertIsNotNone(self.inject(workspace, "frontend", "other.example", "/api"))
        self.assertIsNotNone(self.inject(workspace, "frontend", "git.example", "/api", "http"))

    def test_denied_scope_does_not_partially_rewrite_headers(self):
        workspace = self.load()
        placeholders = " ".join(secret["placeholder"] for secret in self.workspace["secrets"].values())
        request = http.Request.make("GET", "https://git.example/team/frontend.git", headers={"Authorization": placeholders})
        names, error = module.SeterPolicy._inject_request_secrets(
            SimpleNamespace(request=request), workspace, "git.example", "https", "/team/frontend.git"
        )
        self.assertEqual(names, [])
        self.assertIsNotNone(error)
        self.assertEqual(request.headers["Authorization"], placeholders)

    def test_invalid_collections_fail_without_readiness(self):
        for repositories in ([], {"bad": None}, {"../bad": self.workspace["repositories"]["frontend"]}):
            candidate = copy.deepcopy(self.workspace)
            candidate["repositories"] = repositories
            with self.assertRaises(OptionsError):
                self.load(candidate)
            self.assertFalse(self.ready.exists())

    def test_local_only_workspace_has_no_repository_authority(self):
        self.workspace["repositories"] = {}
        self.workspace["secrets"]["frontend"]["repositoryOnly"] = False
        workspace = self.load()
        self.assertIsNone(self.inject(workspace, "frontend", "git.example", "/api"))
        self.assertEqual(workspace["secrets"]["backend"]["repositoryScope"], frozenset())
        self.assertIsNotNone(self.inject(workspace, "backend", "git.example", "/team/backend.git/info/refs"))
        self.assertIsNotNone(self.inject(workspace, "backend", "git.example", "/api"))
    def test_invalid_repository_fields_fail_without_readiness(self):
        for field, value in (("path", "/team/../bad"), ("credential", "missing"), ("host", "unapproved.example")):
            candidate = copy.deepcopy(self.workspace)
            candidate["repositories"]["backend"][field] = value
            with self.assertRaises(OptionsError):
                self.load(candidate)
            self.assertFalse(self.ready.exists())



class PrivateUpstreamTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        (self.directory / "token").write_text("synthetic-private-credential\n")
        self.workspace = {
            "name": "product",
            "httpHosts": ["api.example.com"],
            "passthroughHosts": ["downloads.example.net"],
            "privateHttpHosts": {"Service.LAN.example": "10.0.0.2"},
            "repositories": {},
            "secrets": {
                "token": {
                    "credential": "token",
                    "placeholder": "seter-placeholder-private-0123456789abcdef",
                    "hosts": ["service.lan.example"],
                    "headers": ["authorization"],
                }
            },
        }

    def load(self, workspace=None):
        policy_path = self.directory / "policy.json"
        ready = self.directory / "ready"
        policy_path.write_text(json.dumps({
            "version": 5, "workspaces": {"10.100.0.10": workspace or self.workspace}
        }))
        policy = module.SeterPolicy()
        options = SimpleNamespace(seter_policy=str(policy_path), seter_ready_file=str(ready))
        with patch.object(module.ctx, "options", options, create=True), patch.dict(os.environ, CREDENTIALS_DIRECTORY=str(self.directory)):
            policy.configure({"seter_policy"})
        return policy, policy.workspaces["10.100.0.10"]

    def resolve(self, policy, workspace, host, port):
        import asyncio
        return asyncio.run(policy._resolve_upstream(workspace, host, port))

    def test_private_host_is_an_exact_intercepted_host_with_a_pinned_address(self):
        policy, workspace = self.load()
        self.assertEqual(workspace["privateHttpHosts"], {"service.lan.example": "10.0.0.2"})
        self.assertIn("service.lan.example", workspace["httpHosts"])
        self.assertEqual(self.resolve(policy, workspace, "service.lan.example", 443), ("10.0.0.2", None))
        address, error = self.resolve(policy, workspace, "service.lan.example", 80)
        self.assertIsNone(address)
        self.assertIn("HTTPS on port 443", error)

        request = http.Request.make(
            "GET", "https://service.lan.example/v1/models",
            headers={"Authorization": "Bearer seter-placeholder-private-0123456789abcdef"},
        )
        names, error = module.SeterPolicy._inject_request_secrets(
            SimpleNamespace(request=request), workspace, "service.lan.example", "https", "/v1/models"
        )
        self.assertIsNone(error)
        self.assertEqual(names, ["token"])
        self.assertEqual(request.headers["Authorization"], "Bearer synthetic-private-credential")

    def test_grants_are_scoped_to_their_workspace(self):
        other = copy.deepcopy(self.workspace)
        other["name"] = "other"
        other["privateHttpHosts"] = {"service.lan.example": "10.0.0.3"}
        other["secrets"] = {}
        policy_path = self.directory / "policy.json"
        policy_path.write_text(json.dumps({
            "version": 5,
            "workspaces": {"10.100.0.10": self.workspace, "10.100.0.11": other},
        }))
        policy = module.SeterPolicy()
        options = SimpleNamespace(seter_policy=str(policy_path), seter_ready_file=str(self.directory / "ready"))
        with patch.object(module.ctx, "options", options, create=True), patch.dict(os.environ, CREDENTIALS_DIRECTORY=str(self.directory)):
            policy.configure({"seter_policy"})
        for address, expected in (("10.100.0.10", "10.0.0.2"), ("10.100.0.11", "10.0.0.3")):
            self.assertEqual(
                self.resolve(policy, policy.workspaces[address], "service.lan.example", 443),
                (expected, None),
            )

    def test_public_hosts_never_use_private_addresses(self):
        policy, workspace = self.load()
        with patch.object(module.SeterPolicy, "_lookup_public_ipv4", return_value=(None, "no public address")) as lookup:
            self.assertEqual(self.resolve(policy, workspace, "api.example.com", 443), (None, "no public address"))
        lookup.assert_called_once_with("api.example.com", 443)

    def test_unsafe_private_upstreams_fail_without_readiness(self):
        for grants in (
            {"service.lan.example": "8.8.8.8"},
            {"service.lan.example": "127.0.0.1"},
            {"service.lan.example": "169.254.1.1"},
            {"service.lan.example": "10.0.0.02"},
            {"service.lan.example": 167772162},
            {"*.lan.example": "10.0.0.2"},
            {"10.0.0.3": "10.0.0.2"},
            {"api.example.com": "10.0.0.2"},
            {"downloads.example.net": "10.0.0.2"},
            {"service.lan.example": "10.0.0.2", "SERVICE.lan.example": "10.0.0.3"},
            [],
        ):
            with self.subTest(grants=grants):
                candidate = copy.deepcopy(self.workspace)
                candidate["privateHttpHosts"] = grants
                candidate["secrets"] = {}
                with self.assertRaises(OptionsError):
                    self.load(candidate)
                self.assertFalse((self.directory / "ready").exists())


unittest.main()
