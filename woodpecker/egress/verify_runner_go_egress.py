#!/usr/bin/env python3
"""Read-only Woodpecker runner canary: restricted CONNECT + verified Go module.

Run INSIDE each Go image after the reviewed egress policy is deployed.
No privilege, policy, service or repository mutations. Fail closed.
"""
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

BRIDGE_HOSTS = frozenset(("172.17.0.1", "172.18.0.1"))
MODULE = "github.com/google/uuid@v1.6.0"


def validate_proxy(value: str) -> tuple[str, int]:
    try:
        url = urlsplit(value)
        if (url.scheme != "http" or url.hostname not in BRIDGE_HOSTS or
                url.port != 3188 or url.username or url.password or
                url.path or url.query or url.fragment or
                url.netloc != f"{url.hostname}:{url.port}"):
            raise ValueError("HTTPS_PROXY must point to a private 172.17/18 bridge on port 3188")
    except ValueError as exc:
        raise ValueError("HTTPS_PROXY must point to a private 172.17/18 bridge on port 3188") from exc
    return url.hostname, url.port


def connect_code(host: str, port: int, proxy: tuple[str, int]) -> int:
    with socket.create_connection(proxy, timeout=7) as conn:
        conn.settimeout(10)
        conn.sendall((f"CONNECT {host}:{port} HTTP/1.1\r\n"
                      f"Host: {host}\r\n\r\n").encode("ascii"))
        first_line = b""
        while b"\r\n" not in first_line and len(first_line) < 512:
            part = conn.recv(128)
            if not part:
                break
            first_line += part
        parts = first_line.split(b"\r\n", 1)[0].split(b" ")
        if len(parts) < 2 or parts[0] != b"HTTP/1.1":
            raise RuntimeError(f"bad CONNECT response for {host}:{port}")
        try:
            return int(parts[1])
        except ValueError as exc:
            raise RuntimeError(f"bad CONNECT status for {host}:{port}") from exc


def check_policy(proxy: tuple[str, int]) -> None:
    # Verify the same private listener used by this runner; the operator's
    # deployment helper separately checks BOTH bridge listeners.
    cases = (
        ("proxy.golang.org", 443, 200),
        ("sum.golang.org", 443, 200),
        ("github.com", 443, 200),
        ("unlisted.example", 443, 403),
        ("proxy.golang.org", 80, 403),
    )
    for host, port, expected in cases:
        actual = connect_code(host, port, proxy)
        if actual != expected:
            raise RuntimeError(f"CONNECT {host}:{port} returned {actual}, expected {expected}")
        print(f"PASS CONNECT {host}:{port} status={actual}", flush=True)


def check_go_download(environment: dict[str, str]) -> None:
    # Fresh per-run cache prevents cached modules / sumdb records from
    # concealing a broken module or integrity endpoint.
    proxy = environment["HTTPS_PROXY"]
    with tempfile.TemporaryDirectory(prefix="vertigo-go-proxy-canary-") as dirname:
        root = Path(dirname)
        child = environment.copy()
        child.update({
            "HTTP_PROXY": proxy, "HTTPS_PROXY": proxy, "ALL_PROXY": proxy,
            "http_proxy": proxy, "https_proxy": proxy, "all_proxy": proxy,
            "NO_PROXY": "", "no_proxy": "",
            "GOPROXY": "https://proxy.golang.org",
            "GOSUMDB": "sum.golang.org",
            "GONOSUMDB": "", "GONOPROXY": "", "GOPRIVATE": "",
            "GOINSECURE": "", "GOENV": "off",
            "GOTOOLCHAIN": "local", "GOFLAGS": "", "GOWORK": "off",
            "GOPATH": str(root / "gopath"),
            "GOMODCACHE": str(root / "gopath" / "pkg" / "mod"),
            "GOCACHE": str(root / "gocache"),
        })
        # Deliberately do not use 'go mod download -json': it can encode an
        # Error in its JSON output while exiting with status 0.
        subprocess.run(
            ["go", "mod", "download", MODULE],
            cwd=dirname,
            env=child,
            timeout=120,
            check=True,
            capture_output=True,
            text=True,
        )
        print(f"PASS fresh verified Go module download: {MODULE}", flush=True)


def main() -> int:
    try:
        proxy_text = os.environ.get("HTTPS_PROXY", os.environ.get("https_proxy", ""))
        proxy = validate_proxy(proxy_text)
        print(f"Runner uses restricted proxy at {proxy[0]}:{proxy[1]}", flush=True)
        check_policy(proxy)
        check_go_download({**os.environ, "HTTPS_PROXY": proxy_text})
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
        print(f"FAIL runner Go egress canary: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
