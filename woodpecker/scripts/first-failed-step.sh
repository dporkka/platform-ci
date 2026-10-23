#!/usr/bin/env bash
# Read-only Woodpecker 3.x exact-pipeline failure triage.
# No pipeline mutations, no token arguments, no raw logs by default.
set -Eeuo pipefail

server="${WOODPECKER_SERVER:-https://ci.adacavo.com}"
repo=""
pipeline=""
show_log_excerpt=0

usage() {
  cat <<'HELP'
Usage: first-failed-step.sh --repo OWNER/NAME --pipeline N [--server URL] [--show-log-excerpt]

Read-only inspection using the authenticated woodpecker-cli context on a trusted
host. Prints the earliest started failed step by start timestamp, not dependent
steps that never executed. By default no pipeline logs are fetched or printed.

--show-log-excerpt fetches ONLY the selected failed step's logs and prints a
best-effort-redacted candidate error line. Review even redacted output before
sharing outside the trusted host: secrets can appear in unexpected formats.

Never pass credentials on the command line; use a configured Woodpecker CLI
context or trusted OS keyring. Does not rerun jobs or change repository records.
HELP
}

while (( $# )); do
  case "$1" in
    --server)
      [[ $# -ge 2 ]] || { echo 'missing --server value' >&2; exit 2; }
      server="$2"; shift 2 ;;
    --repo)
      [[ $# -ge 2 ]] || { echo 'missing --repo value' >&2; exit 2; }
      repo="$2"; shift 2 ;;
    --pipeline)
      [[ $# -ge 2 ]] || { echo 'missing --pipeline value' >&2; exit 2; }
      pipeline="$2"; shift 2 ;;
    --show-log-excerpt)
      show_log_excerpt=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'invalid --repo' >&2; exit 2; }
[[ "$pipeline" =~ ^[1-9][0-9]*$ ]] || { echo 'invalid --pipeline' >&2; exit 2; }
[[ "$server" =~ ^https://[A-Za-z0-9_.:-]+/?$ ]] || { echo 'invalid --server; HTTPS required' >&2; exit 2; }
command -v woodpecker-cli >/dev/null 2>&1 || { echo 'woodpecker-cli unavailable on this host' >&2; exit 3; }

# The supported CLI format is one row per workflow child step. The final PID is
# the step-number accepted by 'pipeline log show REPO PIPELINE STEP'.
format='{{ .step.Name }}|{{ .step.State }}|{{ .step.Started }}|{{ .step.PID }}'
if ! steps="$(woodpecker-cli --server "$server" --nocolor pipeline ps "$repo" "$pipeline" --format "$format" 2>/dev/null)"; then
  echo 'pipeline_steps_unavailable: verify trusted host access, authentication, and exact pipeline' >&2
  exit 3
fi

first_name=""
first_state=""
first_start=""
first_pid=""
while IFS='|' read -r name state started pid; do
  [[ -n "$name" ]] || continue
  state="${state,,}"
  case "$state" in
    failure|failed|error|killed) ;;
    *) continue ;;
  esac
  # Ignore steps that never began executing; record their statuses separately
  # in the full pipeline diagnostic.
  [[ "$started" =~ ^[1-9][0-9]*$ ]] || continue
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  if [[ -z "$first_start" ]] || (( 10#$started < 10#$first_start )); then
    first_name="$name"
    first_state="$state"
    first_start="$started"
    first_pid="$pid"
  fi
done <<< "$steps"

if [[ -z "$first_name" ]]; then
  echo 'no_failed_executed_step'
  echo 'Inspect queued/skipped steps and control-plane health with diagnose-control-plane.sh'
  exit 2
fi

printf 'repo=%s\npipeline=%s\nfirst_failed_step=%s\nfirst_failed_state=%s\nfirst_failed_started=%s\nfirst_failed_step_number=%s\n' \
  "$repo" "$pipeline" "$first_name" "$first_state" "$first_start" "$first_pid"

if (( !show_log_excerpt )); then
  echo 'log_not_fetched=true'
  exit 0
fi

# Fetch only the selected step, never the whole pipeline log stream.
if ! logs="$(woodpecker-cli --server "$server" --nocolor pipeline log show "$repo" "$pipeline" "$first_pid" 2>/dev/null)"; then
  echo 'step_logs_unavailable=true'
  exit 3
fi

# This is a heuristic hint, NOT a substitute for investigating the complete
# failing command in trusted logs. Do not print raw log data by default.
candidate="$(printf '%s\n' "$logs" | grep -im1 -E '(^|[^[:alnum:]])(Error:|fatal:|failed|exit code|ERR_)' || true)"
if [[ -z "$candidate" ]]; then
  echo 'log_error_candidate=not_detected'
  exit 0
fi

# Mask common credential forms. Any printed excerpt remains best-effort and
# must be inspected before sharing outside the machine.
candidate="$(printf '%s' "$candidate" | \
  sed -E \
    -e 's/([Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Aa][Pp][Ii]_[Kk][Ee][Yy])([=: ]+)[^[:space:],;]+/\1\2[REDACTED]/g' \
    -e 's/([Bb]earer[[:space:]]+)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/(gh[psu]_[A-Za-z0-9]{5})[A-Za-z0-9]*/[REDACTED]/g')"
printf 'log_error_candidate=%s\n' "${candidate:0:240}"
echo 'log_excerpt_needs_manual_redaction_review=true'
