"""Test the operator's fail-closed Go-module runner canary."""
import subprocess
import unittest
from unittest.mock import patch

import verify_runner_go_egress as canary


class RunnerCanaryTests(unittest.TestCase):
    def test_restricts_proxy_to_private_bridge(self):
        for url in ("http://172.17.0.1:3188", "http://172.18.0.1:3188"):
            self.assertEqual(canary.validate_proxy(url)[1], 3188)
        for url in (
            "", "http://127.0.0.1:3188", "https://172.18.0.1:3188",
            "http://172.18.0.1:8080", "http://user:password@172.18.0.1:3188",
            "http://172.18.0.1:3188/path", "http://172.18.0.1:3188?x=1",
            "http://172.18.0.1:3188#ignored",
        ):
            with self.subTest(url=url), self.assertRaises(ValueError):
                canary.validate_proxy(url)

    def test_go_module_and_checksum_hosts_must_be_allowed(self):
        probes = []
        def probe(host, port, proxy):
            probes.append((host, port))
            return 403 if host == "unlisted.example" or port == 80 else 200
        with patch.object(canary, "connect_code", side_effect=probe):
            canary.check_policy(("172.18.0.1", 3188))
        self.assertEqual(probes, [
            ("proxy.golang.org", 443), ("sum.golang.org", 443),
            ("github.com", 443), ("unlisted.example", 443),
            ("proxy.golang.org", 80),
        ])

    def test_denied_known_origin_fails_before_go_download(self):
        with patch.object(canary, "connect_code", return_value=403):
            with self.assertRaisesRegex(RuntimeError, "proxy.golang.org"):
                canary.check_policy(("172.18.0.1", 3188))

    def test_unknown_host_must_not_be_allowed(self):
        with patch.object(canary, "connect_code", return_value=200):
            with self.assertRaisesRegex(RuntimeError, "unlisted.example"):
                canary.check_policy(("172.18.0.1", 3188))

    def test_go_download_uses_fresh_cache_and_checksum_validation(self):
        calls = []
        def run(args, *, cwd, env, timeout, check, capture_output, text):
            calls.append((args, cwd, env, timeout, check))
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")
        env = {"HTTPS_PROXY": "http://172.18.0.1:3188",
               "NO_PROXY": "proxy.golang.org,sum.golang.org",
               "GONOSUMDB": "*", "GOPRIVATE": "*",
               "GOINSECURE": "*", "GOENV": "/tmp/unsafe-goenv"}
        with patch.object(canary.subprocess, "run", side_effect=run):
            canary.check_go_download(env)
        self.assertEqual(len(calls), 1)
        args, cwd, child, timeout, check = calls[0]
        self.assertEqual(args, ["go", "mod", "download", "github.com/google/uuid@v1.6.0"])
        self.assertTrue(check)
        self.assertEqual(child["GOSUMDB"], "sum.golang.org")
        self.assertEqual(child["GOPROXY"], "https://proxy.golang.org")
        self.assertEqual(child["GOPRIVATE"], "")
        self.assertEqual(child["GONOSUMDB"], "")
        self.assertEqual(child["GOINSECURE"], "")
        self.assertEqual(child["GOENV"], "off")
        self.assertEqual(child["NO_PROXY"], "")
        self.assertEqual(child["HTTPS_PROXY"], env["HTTPS_PROXY"])
        self.assertTrue(child["GOMODCACHE"].startswith(cwd))
        self.assertTrue(child["GOCACHE"].startswith(cwd))
        self.assertEqual(child["GOTOOLCHAIN"], "local")
        self.assertGreater(timeout, 0)

    def test_go_failure_propagates(self):
        with patch.object(canary.subprocess, "run",
                          side_effect=subprocess.CalledProcessError(1, ["go", "mod", "download"])):
            with self.assertRaises(subprocess.CalledProcessError):
                canary.check_go_download({"HTTPS_PROXY": "http://172.18.0.1:3188"})


if __name__ == "__main__":
    unittest.main()
