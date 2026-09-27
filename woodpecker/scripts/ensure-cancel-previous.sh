#!/usr/bin/env bash
set -euo pipefail

server="${WOODPECKER_SERVER:-https://ci.adacavo.com}"
repo_id=""
apply=0

usage() {
  cat <<'USAGE'
Usage: ensure-cancel-previous.sh --repo-id ID [options]

Inspect and optionally repair Woodpecker repository cancellation settings.

Options:
  --server URL   Woodpecker server (default: $WOODPECKER_SERVER or https://ci.adacavo.com)
  --repo-id ID   Numeric Woodpecker repository ID (required)
  --apply        PATCH the setting and verify it afterward
  -h, --help     Show this help

The helper requires WOODPECKER_TOKEN and never prints it. It preserves any
existing cancellation events and ensures pull_request and push are present.
Dry-run is the default.
USAGE
}

while (($#)); do
  case "$1" in
    --server)
      [[ $# -ge 2 ]] || { echo "--server requires a value" >&2; exit 2; }
      server="$2"; shift 2 ;;
    --repo-id)
      [[ $# -ge 2 ]] || { echo "--repo-id requires a value" >&2; exit 2; }
      repo_id="$2"; shift 2 ;;
    --apply)
      apply=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

[[ "$repo_id" =~ ^[0-9]+$ ]] || {
  echo "--repo-id must be a numeric Woodpecker repository ID" >&2
  exit 2
}
: "${WOODPECKER_TOKEN:?WOODPECKER_TOKEN is required}"
command -v curl >/dev/null 2>&1 || {
  echo "curl is required" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required" >&2
  exit 1
}

server="${server%/}"
repo_url="$server/api/repos/$repo_id"
auth_header="Authorization: Bearer $WOODPECKER_TOKEN"

fetch_repo() {
  curl -fsS -H "$auth_header" "$repo_url"
}

analyze_repo() {
  python3 -c '
import json
import sys

expected_id = int(sys.argv[1])
data = json.load(sys.stdin)

repo_id = data.get("id")
full_name = data.get("full_name")
events = data.get("cancel_previous_pipeline_events")

if repo_id != expected_id:
    raise SystemExit(f"repository id mismatch: expected {expected_id}, got {repo_id!r}")
if not isinstance(full_name, str) or not full_name:
    raise SystemExit("repository response is missing full_name")
if not isinstance(events, list) or not all(isinstance(x, str) for x in events):
    raise SystemExit("repository response has invalid cancel_previous_pipeline_events")

desired = list(events)
for event in ("pull_request", "push"):
    if event not in desired:
        desired.append(event)

print(f"repository={full_name}")
print("current_events=" + ",".join(events))
print("desired_events=" + ",".join(desired))
print("needs_repair=" + ("true" if desired != events else "false"))
print("payload=" + json.dumps({"cancel_previous_pipeline_events": desired}, separators=(",", ":")))
' "$repo_id"
}

repo_json="$(fetch_repo)"
analysis="$(printf '%s' "$repo_json" | analyze_repo)"

repository="$(awk -F= '$1=="repository" {print substr($0, index($0, "=")+1)}' <<<"$analysis")"
current_events="$(awk -F= '$1=="current_events" {print substr($0, index($0, "=")+1)}' <<<"$analysis")"
desired_events="$(awk -F= '$1=="desired_events" {print substr($0, index($0, "=")+1)}' <<<"$analysis")"
needs_repair="$(awk -F= '$1=="needs_repair" {print $2}' <<<"$analysis")"
payload="$(awk -F= '$1=="payload" {print substr($0, index($0, "=")+1)}' <<<"$analysis")"

printf 'repository=%s\n' "$repository"
printf 'current_events=%s\n' "$current_events"
printf 'desired_events=%s\n' "$desired_events"

if [[ "$needs_repair" != "true" ]]; then
  printf 'status=ok\n'
  exit 0
fi

if ((apply == 0)); then
  printf 'status=drift\n'
  exit 0
fi

curl -fsS   -X PATCH   -H "$auth_header"   -H 'Content-Type: application/json'   --data-binary "$payload"   "$repo_url" >/dev/null

verified_json="$(fetch_repo)"
verified="$(printf '%s' "$verified_json" | analyze_repo)"
verified_needs_repair="$(awk -F= '$1=="needs_repair" {print $2}' <<<"$verified")"

if [[ "$verified_needs_repair" == "true" ]]; then
  echo "repository setting verification failed after PATCH" >&2
  exit 1
fi

printf 'status=repaired\n'
