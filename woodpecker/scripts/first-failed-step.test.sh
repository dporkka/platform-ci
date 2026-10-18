#!/usr/bin/env bash
# Offline contract tests for the read-only Woodpecker failure inspector.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/woodpecker-cli" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${MOCK_CALL_LOG}"
while [[ "${1:-}" == --* ]]; do
  if [[ "$1" == --server ]]; then shift 2; else shift; fi
done
if [[ "${1:-}" == pipeline && "${2:-}" == ps ]]; then
  case "${MOCK_CASE}" in
    parallel)
      printf '%s\n' 'Lint next|failure|300|8' 'Test|failure|100|3' 'Build|skipped|0|9' ;;
    one)
      printf '%s\n' 'Bootstrap|success|50|1' 'Test|success|100|3' 'Lint server|failure|200|4' ;;
    none)
      printf '%s\n' 'Test|success|100|3' 'Lint server|success|200|4' ;;
    *) exit 70 ;;
  esac
elif [[ "${1:-}" == pipeline && "${2:-}" == log && "${3:-}" == show ]]; then
  printf '%s\n' 'starting command' 'Error: failed module compilation' 'token=woodpecker_not_a_secret'
else
  echo "Unexpected woodpecker-cli command" >&2
  exit 71
fi
MOCK
chmod +x "$work/bin/woodpecker-cli"
export PATH="$work/bin:$PATH"
export MOCK_CALL_LOG="$work/commands"
: > "$MOCK_CALL_LOG"
cmd=(bash "$root/woodpecker/scripts/first-failed-step.sh" --server https://ci.adacavo.com --repo dporkka/websyt.dev --pipeline 499)
check() {
  if ! grep -Fq -- "$2" <<<"$1"; then
    printf 'ASSERTION FAILED: expected [%s] in [%s]\n' "$2" "$1" >&2
    exit 1
  fi
}
export MOCK_CASE=parallel
result="$("${cmd[@]}")"
check "$result" 'first_failed_step=Test'
check "$result" 'first_failed_started=100'
check "$result" 'first_failed_step_number=3'
if grep -Fq 'token=woodpecker_not_a_secret' <<<"$result"; then
  echo 'Raw logs leaked into default output' >&2; exit 1
fi
if grep -Fq 'pipeline log show' "$MOCK_CALL_LOG"; then
  echo 'Default diagnostic unexpectedly fetched log contents' >&2; exit 1
fi

export MOCK_CASE=one
result="$("${cmd[@]}" --show-log-excerpt)"
check "$result" 'first_failed_step=Lint server'
check "$result" 'log_error_candidate='
if grep -Fq 'woodpecker_not_a_secret' <<<"$result"; then
  echo 'Potential secret not redacted from excerpt' >&2; exit 1
fi
check "$(cat "$MOCK_CALL_LOG")" 'pipeline log show dporkka/websyt.dev 499 4'

export MOCK_CASE=none
if "${cmd[@]}" > "$work/none.out" 2>&1; then
  echo 'No failed step was incorrectly considered a success' >&2; exit 1
fi
check "$(cat "$work/none.out")" 'no_failed_executed_step'

printf '%s\n' 'first-failed-step contract tests passed'
