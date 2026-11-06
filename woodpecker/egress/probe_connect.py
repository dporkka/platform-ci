#!/usr/bin/env python3
"""Read-only, credential-free CONNECT policy probe for a private CI bridge.

Run from the same network namespace as the Woodpecker workload being
qualified. A 200 CONNECT response proves only proxy policy + TCP admission;
it is not an OpenTofu success, TLS verification, or a green CI pipeline.
"""
import argparse
import re
import socket

# Exact destinations only. No user-supplied arbitrary external target.
CHECKS = (
    ("registry.opentofu.org", 443, 200),
    ("registry.terraform.io", 443, 200),
    ("github.com", 443, 200),
    ("registry.opentofu.org.attacker.example", 443, 403),
    ("registry.opentofu.org", 80, 403),
)

STATUS = re.compile(rb"^HTTP/1\.[01] ([1-5][0-9]{2}) ")


def probe_connect(proxy_host: str, proxy_port: int, host: str, port: int, timeout: float) -> int | None:
    """Return the CONNECT response status; never send credentials or payload."""
    request = (
        f"CONNECT {host}:{port} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "\r\n"
    ).encode("ascii")
    try:
        with socket.create_connection((proxy_host, proxy_port), timeout=timeout) as conn:
            conn.settimeout(timeout)
            conn.sendall(request)
            reply = b""
            while b"\r\n" not in reply and len(reply) < 256:
                part = conn.recv(256 - len(reply))
                if not part:
                    break
                reply += part
    except OSError:
        return None
    if b"\r\n" not in reply:
        return None
    first = reply.split(b"\r\n", 1)[0]
    match = STATUS.match(first)
    return int(match.group(1)) if match else None


def check_policy(proxy_host: str, proxy_port: int, timeout: float) -> tuple[bool, list[tuple[str, int, int | None, int]]]:
    statuses = []
    for host, port, expected in CHECKS:
        actual = probe_connect(proxy_host, proxy_port, host, port, timeout)
        statuses.append((host, port, actual, expected))
    return all(actual == expected for _, _, actual, expected in statuses), statuses


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--proxy-host", required=True, help="Private bridge hostname/IP; never expose publicly")
    p.add_argument("--proxy-port", type=int, default=3188)
    p.add_argument("--timeout", type=float, default=3)
    args = p.parse_args()
    if not 1 <= args.proxy_port <= 65535 or not 0 < args.timeout <= 10:
        p.error("proxy-port must be 1..65535 and timeout must be >0..10 seconds")
    passed, checks = check_policy(args.proxy_host, args.proxy_port, args.timeout)
    for host, port, actual, expected in checks:
        code = str(actual) if actual is not None else "unreachable_or_invalid"
        outcome = "PASS" if actual == expected else "FAIL"
        print(f"{outcome}: CONNECT {host}:{port} expected={expected} got={code}")
    print("CONNECT_POLICY_PASS" if passed else "CONNECT_POLICY_FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
