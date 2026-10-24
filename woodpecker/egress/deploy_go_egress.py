#!/usr/bin/env python3
"""One-off, fail-closed rollout of the reviewed Woodpecker Go-module egress fix.

Read-only by default. --apply requires an authorized root operator and an idle
CI maintenance window. Does not change Woodpecker or GitHub merge gates.
"""
import argparse
import hashlib
import os
from pathlib import Path
import socket
import stat
import subprocess
import tempfile
import time

from check_deployment import verify_policy

GIT_BLOB = "12dbc637ccad04e98ab54c62b3a8f65d3aa66848"
LIVE = Path("/opt/woodpecker/egress-proxy/github_connect.py")
SERVICE = "woodpecker-github-egress.service"


class GitBlobMismatch(ValueError):
    pass


def verify_candidate(data: bytes) -> None:
    actual = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    if actual != GIT_BLOB:
        raise GitBlobMismatch("candidate differs from reviewed, merged Git blob")


def ensure_idle(sessions) -> None:
    if sessions().strip():
        raise ValueError("active CONNECT sessions on port 3188; defer the rollout")


def current_sessions() -> str:
    cmd = ["ss", "-Htn", "state", "established", "( sport = :3188 )"]
    return subprocess.run(cmd, capture_output=True, text=True, check=True,
                          timeout=8).stdout


def _atomic_replace(path: Path, data: bytes, original_stat) -> None:
    fd, name = tempfile.mkstemp(prefix=".github-connect-rollout-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        os.chmod(name, stat.S_IMODE(original_stat.st_mode))
        if os.geteuid() == 0:
            os.chown(name, original_stat.st_uid, original_stat.st_gid)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def _backup(path: Path, content: bytes, mode: int) -> Path:
    backup = path.with_name(path.name + ".before-go-update")
    flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(backup, flags, mode)
    with os.fdopen(fd, "wb") as file:
        file.write(content)
        file.flush()
        os.fsync(file.fileno())
    return backup


def deploy(candidate: bytes, live: Path, *, sessions, restart, probe,
           sleep=time.sleep) -> None:
    verify_candidate(candidate)
    if live.is_symlink() or not live.is_file():
        raise ValueError("live target must be an existing regular non-symlink file")
    original = live.read_bytes()
    original_stat = live.stat()
    verify_policy(original.decode(), candidate.decode())
    # A zero-connection instant does not establish a quiet maintenance window.
    # Re-sample over ten seconds; CI admission must also be paused externally.
    ensure_idle(sessions)
    sleep(5)
    ensure_idle(sessions)
    sleep(5)
    ensure_idle(sessions)
    # The source could be edited or swapped while CI traffic drains. Do not
    # replace a different operator's change using an obsolete before-image.
    # This is a best-effort check, not an atomic file-system transaction.
    try:
        now = live.lstat()
        unchanged = (
            stat.S_ISREG(now.st_mode)
            and (now.st_dev, now.st_ino, now.st_mtime_ns, now.st_size, now.st_mode)
            == (original_stat.st_dev, original_stat.st_ino,
                original_stat.st_mtime_ns, original_stat.st_size, original_stat.st_mode)
            and live.read_bytes() == original
        )
    except OSError:
        unchanged = False
    if not unchanged:
        raise ValueError("live proxy changed during quiet window; restart preflight")
    _backup(live, original, stat.S_IMODE(original_stat.st_mode))
    changed = False
    try:
        _atomic_replace(live, candidate, original_stat)
        changed = True
        restart()
        probe()
    except Exception as exc:
        if not changed:
            raise
        try:
            _atomic_replace(live, original, original_stat)
            restart()
        except Exception as rollback_error:
            raise RuntimeError(
                f"rollout failed ({exc}); automatic rollback ALSO FAILED ({rollback_error})"
            ) from exc
        raise


def restart_service() -> None:
    subprocess.run(["systemctl", "restart", SERVICE], check=True, timeout=25)
    subprocess.run(["systemctl", "is-active", "--quiet", SERVICE], check=True, timeout=8)


BRIDGE_LISTENERS = ("172.17.0.1", "172.18.0.1")


def _connect_status(host: str, port: int = 443, bridge_ip: str = "172.18.0.1") -> bytes:
    with socket.create_connection((bridge_ip, 3188), timeout=7) as conn:
        conn.settimeout(12)
        conn.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}\r\n\r\n".encode())
        return conn.recv(256).split(b"\r\n", 1)[0]


def probe_service() -> None:
    # Both Docker-private bridge listeners must implement the same allow/deny
    # policy. A healthy listener must not hide a failed or permissive sibling.
    for bridge_ip in BRIDGE_LISTENERS:
        for host in ("proxy.golang.org", "sum.golang.org", "github.com"):
            if not _connect_status(host, bridge_ip=bridge_ip).startswith(b"HTTP/1.1 200 "):
                raise RuntimeError(f"post-restart CONNECT check failed for {host} on {bridge_ip}")
        if not _connect_status("unlisted.example", bridge_ip=bridge_ip).startswith(b"HTTP/1.1 403 "):
            raise RuntimeError(f"post-restart unknown-host deny check failed on {bridge_ip}")
        if not _connect_status("proxy.golang.org", 80, bridge_ip=bridge_ip).startswith(b"HTTP/1.1 403 "):
            raise RuntimeError(f"post-restart non-443 deny check failed on {bridge_ip}")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--candidate", type=Path, required=True)
    p.add_argument("--apply", action="store_true", help="requires authorized root maintenance")
    p.add_argument("--confirm-ci-quiesced", action="store_true",
                   help="operator confirms new CI jobs have been paused")
    args = p.parse_args()

    data = args.candidate.read_bytes()
    verify_candidate(data)
    verify_policy(LIVE.read_text(), data.decode())
    if args.apply and not args.confirm_ci_quiesced:
        raise ValueError("--apply requires --confirm-ci-quiesced after stopping CI job admission")
    ensure_idle(current_sessions)
    if not args.apply:
        print("PASS: reviewed candidate, unchanged proxy logic, and zero live CONNECT sessions")
        print("Read-only preflight; nothing deployed. --apply requires authorized operator.")
        return 0
    if os.geteuid() != 0:
        raise PermissionError("root operator authorization required; no privilege escalation")
    meta = LIVE.lstat()
    if not stat.S_ISREG(meta.st_mode) or meta.st_uid != 0 or meta.st_gid != 0:
        raise ValueError("unexpected live file ownership/type; refuse deployment")
    if stat.S_IMODE(meta.st_mode) != 0o644:
        raise ValueError("unexpected live file mode; refuse deployment")
    subprocess.run(["systemctl", "is-active", "--quiet", SERVICE],
                   check=True, timeout=8)
    deploy(data, LIVE, sessions=current_sessions, restart=restart_service,
           probe=probe_service)
    print("PASS: service restarted, allow/deny probes passed; backup retained")
    print("NEXT: required in-runner Go 1.26/1.27 and PostGIS CI canary")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
