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
            deploy(CANDIDATE, live, capacity_check=lambda _: None, sleep=lambda _: None, sessions=lambda: "", restart=lambda: events.append("restart"),
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
                deploy(CANDIDATE, live, capacity_check=lambda _: None, sleep=lambda _: None, sessions=lambda: "", restart=lambda: events.append("restart"),
                       probe=probe)
            self.assertEqual(live.read_bytes(), OLD)
            self.assertEqual(events, ["restart", "probe", "restart"])

    def test_active_connection_on_second_check_refuses_deployment(self):
        with tempfile.TemporaryDirectory() as td:
            live = Path(td) / "github_connect.py"
            live.write_bytes(OLD)
            reads = iter(("", "ESTAB 0 0 127.0.0.1:3188 172.18.0.2:10000"))
            with self.assertRaisesRegex(ValueError, "active CONNECT"):
                deploy(CANDIDATE, live, capacity_check=lambda _: None, sleep=lambda _: None, sessions=lambda: next(reads), restart=lambda: None,
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
                deploy(CANDIDATE, live, capacity_check=lambda _: None, sleep=lambda _: None, sessions=lambda: "", restart=restart,
                       probe=lambda: self.fail("probe must not run after failed restart"))
            self.assertEqual(live.read_bytes(), OLD)
            self.assertEqual(calls, ["restart", "restart"])

    def test_existing_backup_causes_failure_without_modifying_live(self):
        with tempfile.TemporaryDirectory() as td:
            live = Path(td) / "github_connect.py"
            live.write_bytes(OLD)
            (Path(td) / "github_connect.py.before-go-update").write_bytes(b"existing backup")
            with self.assertRaises(FileExistsError):
                deploy(CANDIDATE, live, capacity_check=lambda _: None, sleep=lambda _: None, sessions=lambda: "", restart=lambda: None,
                       probe=lambda: None)
            self.assertEqual(live.read_bytes(), OLD)

    def test_post_restart_checks_both_private_bridge_listeners(self):
        from unittest.mock import patch
        from deploy_go_egress import probe_service
        observed = []

        def response(host, port=443, bridge_ip="172.18.0.1"):
            observed.append((bridge_ip, host, port))
            if host == "unlisted.example" or port != 443:
                return b"HTTP/1.1 403 Forbidden"
            return b"HTTP/1.1 200 Connection Established"

        with patch("deploy_go_egress._connect_status", side_effect=response):
            probe_service()

        for bridge_ip in ("172.17.0.1", "172.18.0.1"):
            with self.subTest(bridge_ip=bridge_ip):
                self.assertIn((bridge_ip, "proxy.golang.org", 443), observed)
                self.assertIn((bridge_ip, "sum.golang.org", 443), observed)
                self.assertIn((bridge_ip, "github.com", 443), observed)
                self.assertIn((bridge_ip, "unlisted.example", 443), observed)
                self.assertIn((bridge_ip, "proxy.golang.org", 80), observed)

    def test_post_restart_second_bridge_denial_failure_is_not_ignored(self):
        from unittest.mock import patch
        from deploy_go_egress import probe_service

        def response(host, port=443, bridge_ip="172.18.0.1"):
            if bridge_ip == "172.17.0.1" and host == "unlisted.example":
                return b"HTTP/1.1 200 Connection Established"
            if host == "unlisted.example" or port != 443:
                return b"HTTP/1.1 403 Forbidden"
            return b"HTTP/1.1 200 Connection Established"

        with patch("deploy_go_egress._connect_status", side_effect=response):
            with self.assertRaisesRegex(RuntimeError, "deny"):
                probe_service()


    def test_storage_preflight_rejects_low_space_and_high_utilization(self):
        from collections import namedtuple
        from deploy_go_egress import ensure_storage_headroom
        Usage = namedtuple("Usage", "total used free")
        g = 1024 ** 3
        ensure_storage_headroom(Path("/tmp/unused"), disk_usage=lambda _: Usage(100*g, 70*g, 30*g))
        with self.assertRaisesRegex(ValueError, "disk headroom"):
            ensure_storage_headroom(Path("/tmp/unused"), disk_usage=lambda _: Usage(100*g, 70*g, 19*g))
        with self.assertRaisesRegex(ValueError, "disk headroom"):
            ensure_storage_headroom(Path("/tmp/unused"), disk_usage=lambda _: Usage(500*g, 475*g, 25*g))

    def test_storage_preflight_rejects_malformed_capacity_evidence(self):
        from collections import namedtuple
        from deploy_go_egress import ensure_storage_headroom
        Usage = namedtuple("Usage", "total used free")
        for values in [(0, 0, 0), (100, 101, 0), (100, 0, 101), (-1, 0, 0), (100, -1, 0)]:
            with self.subTest(values=values):
                with self.assertRaisesRegex(ValueError, "disk"):
                    ensure_storage_headroom(Path("/tmp/unused"), disk_usage=lambda _, v=values: Usage(*v))

    def test_read_only_operator_preflight_rejects_low_capacity(self):
        from collections import namedtuple
        from unittest.mock import patch
        from deploy_go_egress import main
        Usage = namedtuple("Usage", "total used free")
        g = 1024 ** 3
        with tempfile.TemporaryDirectory() as td:
            live = Path(td) / "github_connect.py"
            live.write_bytes(OLD)
            with patch("deploy_go_egress.LIVE", live), \
                 patch("deploy_go_egress.current_sessions", return_value=""), \
                 patch("deploy_go_egress.shutil.disk_usage",
                       return_value=Usage(500*g, 480*g, 20*g)), \
                 patch("sys.argv", ["deploy_go_egress.py", "--candidate", str(ROOT / "github_connect.py")]):
                with self.assertRaisesRegex(ValueError, "insufficient disk headroom"):
                    main()
            self.assertEqual(live.read_bytes(), OLD)
            self.assertFalse(live.with_name(live.name + ".before-go-update").exists())

    def test_low_disk_during_rollout_does_not_create_backup_or_restart(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as td:
            live = Path(td) / "github_connect.py"
            live.write_bytes(OLD)
            events = []
            with patch("deploy_go_egress.ensure_storage_headroom", side_effect=ValueError("insufficient disk headroom")):
                with self.assertRaisesRegex(ValueError, "disk headroom"):
                    deploy(CANDIDATE, live, sessions=lambda: "", sleep=lambda _: None,
                           restart=lambda: events.append("restart"), probe=lambda: events.append("probe"))
            self.assertEqual(live.read_bytes(), OLD)
            self.assertFalse((Path(td) / "github_connect.py.before-go-update").exists())
            self.assertEqual(events, [])


if __name__ == "__main__":
    unittest.main()
