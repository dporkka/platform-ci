#!/usr/bin/env python3
"""Read-only preflight for the restricted Woodpecker proxy deployment."""
import argparse
import ast
from pathlib import Path

REQUIRED_ADDITIONS = {"proxy.golang.org", "sum.golang.org"}


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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deployed", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    args = parser.parse_args()
    try:
        verify_policy(args.deployed.read_text(), args.candidate.read_text())
    except (ValueError, OSError, SyntaxError) as exc:
        print(f"FAIL: {exc}")
        return 1
    print("PASS: only proxy.golang.org and sum.golang.org added; proxy logic unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
