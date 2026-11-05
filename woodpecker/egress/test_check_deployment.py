"""Read-only deployment preflight contract tests for the egress proxy."""
import pathlib
import tempfile
import unittest
import subprocess
from types import SimpleNamespace
from unittest import mock

from check_deployment import verify_policy, require_idle_proxy

ROOT = pathlib.Path(__file__).parent
ORIGINAL = (ROOT / "github_connect.py").read_text()


class DeploymentPreflightTests(unittest.TestCase):
    def test_idle_proxy_requires_zero_established_connections(self):
        with mock.patch("check_deployment.subprocess.run",
                        return_value=SimpleNamespace(returncode=0, stdout="", stderr="")) as run:
            require_idle_proxy()
        run.assert_called_once_with(
            ["ss", "-Htn", "state", "established", "( sport = :3188 )"],
            capture_output=True, text=True, timeout=8, check=False
        )

    def test_idle_proxy_blocks_when_ci_has_live_connections(self):
        sessions = "0 0 172.18.0.1:3188 172.17.0.3:43864\n"
        with mock.patch("check_deployment.subprocess.run",
                        return_value=SimpleNamespace(returncode=0, stdout=sessions, stderr="")):
            with self.assertRaisesRegex(ValueError, "active"):
                require_idle_proxy()

    def test_idle_proxy_fails_closed_when_ss_fails(self):
        with mock.patch("check_deployment.subprocess.run",
                        return_value=SimpleNamespace(returncode=1, stdout="", stderr="permission denied")):
            with self.assertRaisesRegex(ValueError, "unable to verify"):
                require_idle_proxy()

    def test_idle_proxy_fails_closed_when_ss_missing_or_times_out(self):
        for error in (FileNotFoundError("ss missing"), subprocess.TimeoutExpired("ss", 8)):
            with mock.patch("check_deployment.subprocess.run", side_effect=error):
                with self.assertRaisesRegex(ValueError, "unable to verify"):
                    require_idle_proxy()

    def test_only_websyt_public_audit_host_may_be_newly_added(self):
        deployed = ORIGINAL.replace('    "websyt.dev",\n', '')
        verify_policy(deployed, ORIGINAL)

    def test_only_exact_websyt_lighthouse_origin_may_be_added(self):
        old = ORIGINAL.replace('    "websyt.dev",\n', '')
        verify_policy(old, ORIGINAL)

    def test_unexpected_additional_origin_is_rejected(self):
        old = ORIGINAL.replace('    "websyt.dev",\n', '')
        bad = ORIGINAL.replace(
            '    "websyt.dev",',
            '    "websyt.dev", "attacker.example",',
        )
        with self.assertRaisesRegex(ValueError, "unexpected"):
            verify_policy(old, bad)

    def test_change_outside_allowlist_is_rejected(self):
        old = ORIGINAL.replace('    "websyt.dev",\n', '')
        bad = ORIGINAL.replace(
            'client.sendall(b"HTTP/1.1 403 Forbidden',
            'client.sendall(b"HTTP/1.1 200 OK',
        )
        with self.assertRaisesRegex(ValueError, "outside"):
            verify_policy(old, bad)


if __name__ == "__main__":
    unittest.main()
