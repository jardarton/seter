"""Shared contract tests, including the real DNS and proxy policy loaders."""

import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import host_patterns as patterns
from mitmproxy.exceptions import OptionsError
from mitmproxy.addons.script import load_script

bundle = Path(sys.argv.pop(1))
cases = json.loads(Path(sys.argv.pop(1)).read_text())


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


dns_policy = load_module("dns_policy", bundle / "dns-policy.py")
proxy_policy = load_script(str(bundle / "proxy-addon.py"))
assert proxy_policy is not None, "mitmproxy could not load the packaged addon"


class HostPatternTests(unittest.TestCase):
    def test_shared_contract(self):
        for case in cases["hosts"]:
            with self.subTest(case=case["label"]):
                self.assertEqual(patterns.exact_valid(case["input"]), case["exact"])
                if case["pattern"]:
                    self.assertEqual(patterns.canonical_pattern(case["input"]), case["canonical"])
                else:
                    with self.assertRaises(ValueError):
                        patterns.canonical_pattern(case["input"])
        for case in cases["matches"]:
            with self.subTest(match=case):
                self.assertEqual(patterns.pattern_matches(case["pattern"], case["host"]), case["matches"])
        for case in cases["overlaps"]:
            with self.subTest(overlap=case):
                self.assertEqual(patterns.patterns_overlap(case["left"], case["right"]), case["overlaps"])

    def test_request_names_allow_one_root_dot(self):
        self.assertEqual(patterns.request_host("API.Example.COM."), "api.example.com")
        for value in [None, "api.example.com..", "a!.example.com", "K.example.com"]:
            self.assertEqual(patterns.request_host(value), "")

    def test_dns_loader_uses_shared_validation(self):
        config = {
            "version": 1, "workspace": "example", "sourceAddress": "10.100.0.10",
            "backendAddress": "127.0.0.1", "backendPort": 15353,
            "logQueries": False, "upstreamTimeoutSeconds": 3,
            "maxConcurrentQueries": 64, "queriesPerSecond": 200, "queryBurst": 400,
        }
        for case in cases["hosts"]:
            with self.subTest(case=case["label"]):
                config["allowedNames"] = [case["input"]]
                if case["pattern"]:
                    server = dns_policy.PolicyServer(config)
                    self.assertEqual(server.allowed_names, {case["canonical"]})
                else:
                    with self.assertRaises(ValueError):
                        dns_policy.PolicyServer(config)

    def test_proxy_loader_uses_shared_validation(self):
        workspace = {
            "name": "example", "httpHosts": ["git.example"], "passthroughHosts": [],
            "repositories": {"example": {"host": "git.example", "path": "/team/example.git", "credential": None}},
            "secrets": {},
        }
        with tempfile.TemporaryDirectory() as directory:
            policy_file = Path(directory) / "policy.json"
            ready_file = Path(directory) / "ready"
            options = SimpleNamespace(seter_policy=str(policy_file), seter_ready_file=str(ready_file))
            with patch.object(proxy_policy.ctx, "options", options, create=True):
                for field in ["httpHosts", "passthroughHosts"]:
                    for case in cases["hosts"]:
                        with self.subTest(field=field, case=case["label"]):
                            value = copy.deepcopy(workspace)
                            value[field].append(case["input"])
                            policy_file.write_text(json.dumps({"version": 4, "workspaces": {"10.100.0.10": value}}))
                            policy = proxy_policy.SeterPolicy()
                            if case["pattern"]:
                                policy.configure({"seter_policy"})
                                self.assertTrue(ready_file.exists())
                                self.assertIn(case["canonical"], policy.workspaces["10.100.0.10"][field])
                            else:
                                # A previous successful load must not leave a
                                # readiness marker when the new policy fails.
                                ready_file.touch()
                                with self.assertRaises(OptionsError):
                                    policy.configure({"seter_policy"})
                                self.assertFalse(ready_file.exists())


if __name__ == "__main__":
    unittest.main()
