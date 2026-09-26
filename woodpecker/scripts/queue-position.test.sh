#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/woodpecker/scripts/queue-position.sh"

[[ -x "$SCRIPT" ]] || {
  printf 'FAIL: expected executable queue classifier at %s\n' "$SCRIPT" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/queue.txt" <<'EOF'
dporkka/websyt.dev|304|pending|aaaaaaaa
dporkka/nulang-cloud|3062|pending|bbbbbbbb
dporkka/ochem-app|57|pending|cccccccc
EOF

out="$("$SCRIPT" dporkka/nulang-cloud 3062 <"$tmp/queue.txt")"
grep -Fx 'queue_depth=3' <<<"$out" >/dev/null
grep -Fx 'repo_queue_depth=1' <<<"$out" >/dev/null
grep -Fx 'target_position=2' <<<"$out" >/dev/null
grep -Fx 'classification=backlog' <<<"$out" >/dev/null

out="$("$SCRIPT" dporkka/nulang-cloud 9999 <"$tmp/queue.txt")"
grep -Fx 'queue_depth=3' <<<"$out" >/dev/null
grep -Fx 'repo_queue_depth=1' <<<"$out" >/dev/null
grep -Fx 'target_position=not-found' <<<"$out" >/dev/null
grep -Fx 'classification=not-queued' <<<"$out" >/dev/null

cat >"$tmp/first.txt" <<'EOF'
dporkka/nulang-cloud|3062|pending|bbbbbbbb
dporkka/websyt.dev|304|pending|aaaaaaaa
EOF
out="$("$SCRIPT" dporkka/nulang-cloud 3062 <"$tmp/first.txt")"
grep -Fx 'target_position=1' <<<"$out" >/dev/null
grep -Fx 'classification=next' <<<"$out" >/dev/null

: >"$tmp/empty.txt"
out="$("$SCRIPT" dporkka/nulang-cloud 3062 <"$tmp/empty.txt")"
grep -Fx 'queue_depth=0' <<<"$out" >/dev/null
grep -Fx 'repo_queue_depth=0' <<<"$out" >/dev/null
grep -Fx 'target_position=not-found' <<<"$out" >/dev/null
grep -Fx 'classification=empty' <<<"$out" >/dev/null

cat >"$tmp/repo.txt" <<'EOF'
dporkka/nulang-cloud|3055|pending|11111111
dporkka/nulang-cloud|3062|pending|22222222
EOF
out="$("$SCRIPT" dporkka/nulang-cloud <"$tmp/repo.txt")"
grep -Fx 'repo_queue_depth=2' <<<"$out" >/dev/null
grep -Fx 'classification=repo-queued' <<<"$out" >/dev/null

printf 'Woodpecker queue position classifier behavior is correct.\n'
