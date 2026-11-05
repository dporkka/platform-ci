"""Read-only deployment preflight contract tests for the egress proxy."""
import pathlib
import tempfile
import unittest

from check_deployment import verify_policy

ROOT = pathlib.Path(__file__).parent
ORIGINAL = (ROOT / "github_connect.py").read_text()


class DeploymentPreflightTests(unittest.TestCase):
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
