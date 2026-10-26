#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/df" <<'MOCK'
#!/bin/sh
case "${TEST_DF_CASE:-ok}" in
  ok) printf '1B-blocks Used Avail Use%%\n519691042816 468151435264 51539607552 91%%\n' ;;
  low_free) printf '1B-blocks Used Avail Use%%\n519691042816 503584800768 16106127360 96%%\n' ;;
  high_percent) printf '1B-blocks Used Avail Use%%\n519691042816 493921239040 25769803776 95%%\n' ;;
  missing_percent) printf '1B-blocks Used Avail Use%%\n519691042816 468151435264 51539607552 91\n' ;;
  broken) printf '1B-blocks Used Avail Use%%\n1 no-data 0 unknown\n' ;;
  unavailable) exit 66 ;;
  *) exit 67 ;;
esac
MOCK
chmod 700 "$tmp/bin/df"
export PATH="$tmp/bin:$PATH"
case_result() {
  local expected="$1" marker="$2" scenario="$3"; shift 3
  local rc=0
  TEST_DF_CASE="$scenario" bash "$here/check-disk-headroom.sh" "$@" > "$tmp/output" 2>&1 || rc=$?
  if [[ "$rc" -ne "$expected" ]]; then
    echo "FAIL scenario=$scenario expected exit $expected, got $rc" >&2
    cat "$tmp/output" >&2
    exit 1
  fi
  if ! grep -Fq -- "$marker" "$tmp/output"; then
    echo "FAIL scenario=$scenario missing marker '$marker'" >&2
    cat "$tmp/output" >&2
    exit 1
  fi
}
case_result 0 'status=ok' ok
case_result 1 'status=blocked' low_free
case_result 1 'status=blocked' high_percent
case_result 2 'status=error' missing_percent
case_result 2 'status=error' broken
case_result 2 'status=error' unavailable
case_result 2 'status=error' ok --min-free-gib -1
case_result 2 'status=error' ok --max-used-percent 101
case_result 2 'status=error' ok --unknown
case_result 1 'status=blocked' ok --min-free-gib 60
case_result 0 'status=ok' ok --min-free-gib 20 --max-used-percent 92
echo 'PASS: 11 offline fail-closed disk-headroom cases'
