"""Operator-only admission preflight must reject transient CI traffic."""
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

from deploy_go_egress import deploy, main

CANDIDATE = (Path(__file__).parent / "github_connect.py").read_bytes()
OLD = CANDIDATE.replace(b'    "proxy.golang.org", "sum.golang.org",\n', b"")


class QuiescenceTests(unittest.TestCase):
    def test_transient_new_connection_refuses_rollout(self):
        with tempfile.TemporaryDirectory() as dirname:
            live = Path(dirname) / "github_connect.py"
            live.write_bytes(OLD)
            samples = iter(("", "", "ESTAB 0 0 172.18.0.1:3188 172.18.0.2:52334"))
            with self.assertRaisesRegex(ValueError, "active CONNECT"):
                deploy(
                    CANDIDATE,
                    live,
                    sessions=lambda: next(samples),
                    sleep=lambda _: None,
                    restart=lambda: None,
                    probe=lambda: None,
                )
            self.assertEqual(live.read_bytes(), OLD, "live proxy changed during active CI traffic")
            self.assertFalse(live.with_name(live.name + ".before-go-update").exists())

    def test_quiet_window_uses_spaced_samples(self):
        with tempfile.TemporaryDirectory() as dirname:
            live = Path(dirname) / "github_connect.py"
            live.write_bytes(OLD)
            pauses = []
            deploy(
                CANDIDATE,
                live,
                sessions=lambda: "",
                restart=lambda: None,
                probe=lambda: None,
                sleep=pauses.append,
                capacity_check=lambda _: None,
            )
            self.assertGreaterEqual(len(pauses), 2)
            self.assertTrue(all(seconds >= 5 for seconds in pauses))
            self.assertEqual(live.read_bytes(), CANDIDATE)

    def test_apply_requires_acknowledgment_of_quiesced_ci(self):
        with tempfile.TemporaryDirectory() as dirname:
            live = Path(dirname) / "github_connect.py"
            live.write_bytes(OLD)
            with patch("deploy_go_egress.LIVE", live), \
                 patch("deploy_go_egress.current_sessions", return_value=""), \
                 patch("deploy_go_egress.os.geteuid", return_value=1002), \
                 patch("sys.argv", ["deploy_go_egress.py", "--candidate", str(Path(__file__).parent / "github_connect.py"), "--apply"]):
                with self.assertRaisesRegex(ValueError, "confirm"):
                    main()
            self.assertEqual(live.read_bytes(), OLD)


if __name__ == "__main__":
    unittest.main()


class LiveSourceRaceTests(unittest.TestCase):
    def test_external_change_during_quiet_window_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as dirname:
            live = Path(dirname) / "github_connect.py"
            live.write_bytes(OLD)
            external = OLD + b"\n# changed by another operator\n"
            pauses = []
            def pause(seconds):
                pauses.append(seconds)
                if len(pauses) == 1:
                    live.write_bytes(external)
            with self.assertRaisesRegex(ValueError, "live proxy changed"):
                deploy(CANDIDATE, live, sessions=lambda: "",
                       sleep=pause, restart=lambda: self.fail("must not restart"),
                       probe=lambda: self.fail("must not probe"))
            self.assertEqual(live.read_bytes(), external)
            self.assertFalse(live.with_name(live.name + ".before-go-update").exists())

    def test_symlink_swap_during_quiet_window_does_not_overwrite_target(self):
        with tempfile.TemporaryDirectory() as dirname:
            live = Path(dirname) / "github_connect.py"
            outside = Path(dirname) / "outside.py"
            live.write_bytes(OLD)
            outside.write_bytes(b"outside must be untouched")
            waits = []
            def pause(seconds):
                waits.append(seconds)
                if len(waits) == 1:
                    live.unlink()
                    live.symlink_to(outside)
            with self.assertRaisesRegex(ValueError, "live proxy changed"):
                deploy(CANDIDATE, live, sessions=lambda: "",
                       sleep=pause, restart=lambda: self.fail("must not restart"),
                       probe=lambda: self.fail("must not probe"))
            self.assertTrue(live.is_symlink())
            self.assertEqual(outside.read_bytes(), b"outside must be untouched")
            self.assertFalse(live.with_name(live.name + ".before-go-update").exists())
