#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/woodpecker/scripts/ensure-cancel-previous.sh"

[[ -x "$SCRIPT" ]] || {
  printf 'FAIL: expected executable cancel-previous helper at %s\n' "$SCRIPT" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKEBIN="$TMP/bin"
mkdir -p "$FAKEBIN"

cat >"$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

method="GET"
payload=""
url=""
while (($#)); do
  case "$1" in
    -X|--request)
      method="$2"; shift 2 ;;
    -d|--data|--data-raw|--data-binary)
      payload="$2"; shift 2 ;;
    -H|--header)
      shift 2 ;;
    -f|-s|-S|-fsS)
      shift ;;
    http*)
      url="$1"; shift ;;
    *)
      shift ;;
  esac
done

[[ "$url" == *"/api/repos/14" ]] || {
  printf 'unexpected URL: %s\n' "$url" >&2
  exit 22
}

if [[ "$method" == "PATCH" ]]; then
  printf '%s\n' "$payload" >"$PATCH_LOG"
  python3 - "$STATE_FILE" "$payload" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
state = json.loads(path.read_text())
patch = json.loads(sys.argv[2])
state.update(patch)
path.write_text(json.dumps(state))
print(json.dumps(state))
PY
else
  cat "$STATE_FILE"
fi
EOF
chmod +x "$FAKEBIN/curl"

export PATH="$FAKEBIN:/usr/bin:/bin"
export STATE_FILE="$TMP/state.json"
export PATCH_LOG="$TMP/patch.log"
export WOODPECKER_TOKEN="test-token"

cat >"$STATE_FILE" <<'JSON'
{"id":14,"full_name":"dporkka/nulang-cloud","cancel_previous_pipeline_events":["pull_request","push"]}
JSON
: >"$PATCH_LOG"
out="$("$SCRIPT" --server https://ci.adacavo.com --repo-id 14)"
grep -Fx 'repository=dporkka/nulang-cloud' <<<"$out" >/dev/null
grep -Fx 'current_events=pull_request,push' <<<"$out" >/dev/null
grep -Fx 'desired_events=pull_request,push' <<<"$out" >/dev/null
grep -Fx 'status=ok' <<<"$out" >/dev/null
[[ ! -s "$PATCH_LOG" ]] || {
  printf 'FAIL: already-correct state must not PATCH\n' >&2
  exit 1
}

cat >"$STATE_FILE" <<'JSON'
{"id":14,"full_name":"dporkka/nulang-cloud","cancel_previous_pipeline_events":["push"]}
JSON
: >"$PATCH_LOG"
out="$("$SCRIPT" --server https://ci.adacavo.com --repo-id 14)"
grep -Fx 'current_events=push' <<<"$out" >/dev/null
grep -Fx 'desired_events=push,pull_request' <<<"$out" >/dev/null
grep -Fx 'status=drift' <<<"$out" >/dev/null
[[ ! -s "$PATCH_LOG" ]] || {
  printf 'FAIL: dry-run drift check must not PATCH\n' >&2
  exit 1
}

cat >"$STATE_FILE" <<'JSON'
{"id":14,"full_name":"dporkka/nulang-cloud","cancel_previous_pipeline_events":["manual"]}
JSON
: >"$PATCH_LOG"
out="$("$SCRIPT" --server https://ci.adacavo.com --repo-id 14 --apply)"
grep -Fx 'current_events=manual' <<<"$out" >/dev/null
grep -Fx 'desired_events=manual,pull_request,push' <<<"$out" >/dev/null
grep -Fx 'status=repaired' <<<"$out" >/dev/null
python3 - "$PATCH_LOG" <<'PY'
import json, pathlib, sys
patch = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert patch == {"cancel_previous_pipeline_events": ["manual", "pull_request", "push"]}, patch
PY
python3 - "$STATE_FILE" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert state["cancel_previous_pipeline_events"] == ["manual", "pull_request", "push"], state
PY

unset WOODPECKER_TOKEN
if "$SCRIPT" --server https://ci.adacavo.com --repo-id 14 >/dev/null 2>&1; then
  printf 'FAIL: helper must fail closed without WOODPECKER_TOKEN\n' >&2
  exit 1
fi

printf 'Woodpecker cancel-previous repository contract behavior is correct.\n'
