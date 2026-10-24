"""Dry-run and transactional rollout checks for the one-off Go egress update."""
import tempfile
import unittest
from pathlib import Path

from deploy_go_egress import deploy, ensure_idle, verify_candidate, GitBlobMismatch

ROOT = Path(__file__).parent
CANDIDATE = (ROOT / "github_connect.py").read_bytes()
OLD = CANDIDATE.replace(b'    "proxy.golang.org", "sum.golang.org",\n', b"")


class DeploymentTests(unittest.TestCase):
    def test_candidate_is_pinned_to_reviewed_blob(self):
        verify_candidate(CANDIDATE)
        with self.assertRaises(GitBlobMismatch):
            verify_candidate(CANDIDATE + b"\n#changed\n")

    def test_busy_proxy_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "active CONNECT"):
            ensure_idle(lambda: "ESTAB 0 0 127.0.0.1:3188 172.18.0.2:10000")
        ensure_idle(lambda: "")

    def test_approved_rollout_updates_source_and_retains_backup(self):
        with tempfile.TemporaryDirectory() as td:
            live = Path(td) / "github_connect.py"
            live.write_bytes(OLD)
            events = []
            deploy(CANDIDATE, live, sessions=lambda: "", restart=lambda: events.append("restart"),
                   probe=lambda: events.append("probe"))
            self.assertEqual(live.read_bytes(), CANDIDATE)
            self.assertEqual((Path(td) / "github_connect.py.before-go-update").read_bytes(), OLD)
            self.assertEqual(events, ["restart", "probe"])

    def test_failed_probe_restores_old_policy_and_restarts(self):
        with tempfile.TemporaryDirectory() as td:
            live = Path(td) / "github_connect.py"
            live.write_bytes(OLD)
            events = []
            def probe():
                events.append("probe")
                raise RuntimeError("failed post-restart probe")
            with self.assertRaisesRegex(RuntimeError, "failed post-restart probe"):
                deploy(CANDIDATE, live, sessions=lambda: "", restart=lambda: events.append("restart"),
                       probe=probe)
            self.assertEqual(live.read_bytes(), OLD)
            self.assertEqual(events, ["restart", "probe", "restart"])

    def test_active_connection_on_second_check_refuses_deployment(self):
        with tempfile.TemporaryDirectory() as td:
            live = Path(td) / "github_connect.py"
            live.write_bytes(OLD)
            reads = iter(("", "ESTAB 0 0 127.0.0.1:3188 172.18.0.2:10000"))
            with self.assertRaisesRegex(ValueError, "active CONNECT"):
                deploy(CANDIDATE, live, sessions=lambda: next(reads), restart=lambda: None,
                       probe=lambda: None)
            self.assertEqual(live.read_bytes(), OLD)

    def test_failed_restart_restores_original_policy(self):
        with tempfile.TemporaryDirectory() as td:
            live = Path(td) / "github_connect.py"
            live.write_bytes(OLD)
            calls = []
            def restart():
                calls.append("restart")
                if len(calls) == 1:
                    raise RuntimeError("restart failure")
            with self.assertRaisesRegex(RuntimeError, "restart failure"):
                deploy(CANDIDATE, live, sessions=lambda: "", restart=restart,
                       probe=lambda: self.fail("probe must not run after failed restart"))
            self.assertEqual(live.read_bytes(), OLD)
            self.assertEqual(calls, ["restart", "restart"])

    def test_existing_backup_causes_failure_without_modifying_live(self):
        with tempfile.TemporaryDirectory() as td:
            live = Path(td) / "github_connect.py"
            live.write_bytes(OLD)
            (Path(td) / "github_connect.py.before-go-update").write_bytes(b"existing backup")
            with self.assertRaises(FileExistsError):
                deploy(CANDIDATE, live, sessions=lambda: "", restart=lambda: None,
                       probe=lambda: None)
            self.assertEqual(live.read_bytes(), OLD)


if __name__ == "__main__":
    unittest.main()
