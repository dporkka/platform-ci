"""Read-only deployment preflight contract tests for the egress proxy."""
import pathlib
import tempfile
import unittest

from check_deployment import verify_policy

ROOT = pathlib.Path(__file__).parent
ORIGINAL = (ROOT / "github_connect.py").read_text()
# The live CI proxy already has the Go endpoints; the Python hosts are the
# narrowly approved delta for this release candidate.
DEPLOYED = ORIGINAL.replace(
    '    "pypi.org", "files.pythonhosted.org",\n',
    '',
)
assert DEPLOYED != ORIGINAL


class DeploymentPreflightTests(unittest.TestCase):
    def test_deployed_go_policy_is_preserved_and_extra_hosts_fail_closed(self):
        self.assertIn('"proxy.golang.org"', DEPLOYED)
        self.assertIn('"sum.golang.org"', DEPLOYED)
        removed_go = ORIGINAL.replace('"proxy.golang.org", "sum.golang.org",', '')
        with self.assertRaisesRegex(ValueError, "removal"):
            verify_policy(DEPLOYED, removed_go)

    def test_only_required_python_package_hosts_may_be_added(self):
        verify_policy(DEPLOYED, ORIGINAL)

    def test_unexpected_additional_origin_is_rejected(self):
        bad = ORIGINAL.replace(
            '"files.pythonhosted.org",',
            '"files.pythonhosted.org", "attacker.example",',
        )
        with self.assertRaisesRegex(ValueError, "unexpected"):
            verify_policy(DEPLOYED, bad)

    def test_missing_one_required_python_origin_is_rejected(self):
        bad = ORIGINAL.replace('"files.pythonhosted.org",', '')
        with self.assertRaisesRegex(ValueError, "unexpected additions"):
            verify_policy(DEPLOYED, bad)

    def test_change_outside_allowlist_is_rejected(self):
        modified = ORIGINAL.replace(
            'client.sendall(b"HTTP/1.1 403 Forbidden',
            'client.sendall(b"HTTP/1.1 200 OK',
        )
        with self.assertRaisesRegex(ValueError, "outside"):
            verify_policy(DEPLOYED, modified)


if __name__ == "__main__":
    unittest.main()
