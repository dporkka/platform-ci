#!/usr/bin/env python3
"""Read-only preflight for the restricted Woodpecker proxy deployment."""
import argparse
import ast
import subprocess
from pathlib import Path

REQUIRED_ADDITIONS = {"websyt.dev"}


def _parts(source: str) -> tuple[set[str], list[str]]:
    allowlist = None
    remaining = []
    for node in ast.parse(source).body:
        if (isinstance(node, ast.Assign)
                and any(isinstance(t, ast.Name) and t.id == "ALLOWED" for t in node.targets)):
            if allowlist is not None:
                raise ValueError("duplicate ALLOWED declaration")
            if not isinstance(node.value, ast.Call) or len(node.value.args) != 1:
                raise ValueError("unexpected ALLOWED expression")
            if not isinstance(node.value.func, ast.Name) or node.value.func.id != "frozenset":
                raise ValueError("unexpected ALLOWED constructor")
            allowlist = set(ast.literal_eval(node.value.args[0]))
        else:
            remaining.append(ast.dump(node, include_attributes=False))
    if allowlist is None:
        raise ValueError("missing ALLOWED declaration")
    return allowlist, remaining


def verify_policy(deployed: str, candidate: str) -> None:
    existing, existing_logic = _parts(deployed)
    proposed, proposed_logic = _parts(candidate)
    if existing_logic != proposed_logic:
        raise ValueError("changes outside destination allowlist")
    if existing - proposed:
        raise ValueError("unexpected removal from existing allowlist")
    if proposed - existing != REQUIRED_ADDITIONS:
        raise ValueError("unexpected additions to destination allowlist")
    if "*" in proposed:
        raise ValueError("unexpected wildcard destination")


def require_idle_proxy() -> None:
    """Fail closed if the live private proxy has established CONNECT sessions.

    Read-only preflight. A separate privileged installer must verify the
    host is still idle immediately before a restart (avoid TOCTOU races).
    """
    try:
        result = subprocess.run(
            ["ss", "-Htn", "state", "established", "( sport = :3188 )"],
            capture_output=True, text=True, timeout=8, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ValueError("unable to verify proxy idle state") from exc
    if result.returncode != 0:
        raise ValueError("unable to verify proxy idle state")
    if result.stdout.strip():
        raise ValueError("active CI CONNECT sessions; do not restart proxy")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deployed", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--require-idle", action="store_true", help="refuse deployment preflight while proxy has live sessions")
    args = parser.parse_args()
    try:
        verify_policy(args.deployed.read_text(), args.candidate.read_text())
        if args.require_idle:
            require_idle_proxy()
    except (ValueError, OSError, SyntaxError) as exc:
        print(f"FAIL: {exc}")
        return 1
    print("PASS: only websyt.dev added; proxy logic unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
