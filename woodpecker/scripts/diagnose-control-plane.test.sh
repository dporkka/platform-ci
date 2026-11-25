#!/usr/bin/env bash
# Regression: an exact pipeline request must not return success if queue,
# pipeline and step inspection could not run under authenticated Woodpecker CLI.
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'SH'
#!/bin/sh
printf 204
SH
cat >"$tmp/bin/getent" <<'SH'
#!/bin/sh
printf '127.0.0.1 STREAM ci.adacavo.com\n'
SH
cat >"$tmp/bin/docker" <<'SH'
#!/bin/sh
exit 0
SH
cat >"$tmp/bin/podman" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$tmp/bin/"*
chmod +x "$script_dir/queue-position.sh"
# Use an isolated tool PATH so a host-installed authenticated Woodpecker CLI
# cannot invalidate the missing-CLI regression. Only explicitly whitelisted
# read-only utility commands are available until the mock CLI is installed.
for tool in bash dirname mktemp rm sed awk grep head tr cat wc sort; do
  resolved="$(command -v "$tool")"
  [[ "$resolved" == /* ]] || continue
  ln -s "$resolved" "$tmp/bin/$tool"
done
test_path="$tmp/bin"

diagnose() {
  PATH="$test_path" bash "$script_dir/diagnose-control-plane.sh" \
    --server https://ci.adacavo.com --repo dporkka/vertigo "$@"
}
# Without an exact target, health-only mode may still be a useful success.
if ! diagnose >"$tmp/generic.out" 2>&1; then
  echo "FAIL: generic health check should remain usable without Woodpecker auth" >&2
  cat "$tmp/generic.out" >&2
  exit 1
fi
# With --pipeline, success without authenticated pipeline/step proof is unsafe.
if diagnose --pipeline 511 >"$tmp/missing.out" 2>&1; then
  echo "FAIL: requested pipeline 511 returned success without authenticated CLI" >&2
  exit 1
fi
if ! grep -q 'FAIL:.*Woodpecker CLI.*pipeline 511' "$tmp/missing.out"; then
  echo "FAIL: missing exact pipeline inspection was not reported clearly" >&2
  cat "$tmp/missing.out" >&2
  exit 1
fi
cat >"$tmp/bin/woodpecker-cli" <<'SH'
#!/bin/sh
# --server URL <subcommand>
shift 2
case "$1 $2" in
  'info ') echo 'Woodpecker authenticated';;
  'repo ls') echo 'dporkka/vertigo';;
  'pipeline queue') echo 'dporkka/vertigo|511|pending|abc';;
  'pipeline show') echo 'pipeline 511 pending';;
  'pipeline ps') echo 'step prepare pending';;
  *) echo "unexpected CLI args: $*" >&2; exit 7;;
esac
SH
chmod +x "$tmp/bin/woodpecker-cli"
if ! diagnose --pipeline 511 >"$tmp/authorized.out" 2>&1; then
  echo "FAIL: fully readable pipeline metadata should not be classified as missing" >&2
  cat "$tmp/authorized.out" >&2
  exit 1
fi
# Pipeline metadata alone is not sufficient for queue diagnosis.
sed -i "s/'pipeline queue') echo 'dporkka\/vertigo|511|pending|abc';;/'pipeline queue') echo 'authorization denied' >\&2; exit 1;;/" "$tmp/bin/woodpecker-cli"
if diagnose --pipeline 511 >"$tmp/queue-denied.out" 2>&1; then
  echo "FAIL: denied queue inspection returned success for pipeline 511" >&2
  exit 1
fi
if ! grep -q 'FAIL:.*queue.*pipeline 511' "$tmp/queue-denied.out"; then
  echo "FAIL: missing queue evidence not reported as failure" >&2
  cat "$tmp/queue-denied.out" >&2
  exit 1
fi
# A healthy /healthz is not enough to notice a failing local OAuth refresh
# timer. Exercise only whitelisted, non-sensitive systemd unit state.
cat >"$tmp/bin/systemctl" <<'SH'
#!/bin/sh
case "$*" in
  *woodpecker-github-oauth-refresh.service*) ;;
  *) echo "unexpected systemctl request" >&2; exit 9 ;;
esac
case "${MOCK_OAUTH_CASE:-failed}" in
  failed)
    printf 'LoadState=loaded\nActiveState=failed\nResult=exit-code\nExecMainStatus=1\n'
    ;;
  healthy)
    printf 'LoadState=loaded\nActiveState=inactive\nResult=success\nExecMainStatus=0\n'
    ;;
  missing)
    printf 'LoadState=not-found\nActiveState=inactive\nResult=success\nExecMainStatus=0\n'
    ;;
esac
SH
chmod +x "$tmp/bin/systemctl"
MOCK_OAUTH_CASE=failed diagnose >"$tmp/oauth-failed.out" 2>&1
if ! grep -q 'WARN:.*OAuth refresh.*failed' "$tmp/oauth-failed.out"; then
  echo "FAIL: failed local OAuth refresher not reported despite healthy HTTP" >&2
  cat "$tmp/oauth-failed.out" >&2
  exit 1
fi
MOCK_OAUTH_CASE=healthy diagnose >"$tmp/oauth-healthy.out" 2>&1
if grep -q 'WARN:.*OAuth refresh' "$tmp/oauth-healthy.out"; then
  echo "FAIL: healthy inactive oneshot falsely flagged" >&2
  cat "$tmp/oauth-healthy.out" >&2
  exit 1
fi
MOCK_OAUTH_CASE=missing diagnose >"$tmp/oauth-missing.out" 2>&1
if grep -q 'WARN:.*OAuth refresh' "$tmp/oauth-missing.out"; then
  echo "FAIL: missing optional local OAuth unit falsely flagged" >&2
  cat "$tmp/oauth-missing.out" >&2
  exit 1
fi
echo "PASS: OAuth refresh status is read-only and distinguishes failure from healthy/absent"
echo "PASS: exact pipeline diagnosis fails closed; generic health remains usable"

# Woodpecker 3.19 requires WOODPECKER_AGENT_LABELS, not the old
# WOODPECKER_LABELS environment variable. Exercise one local bootstrap agent
# with a simulated read-only Docker inspect result.
cat >"$tmp/bin/docker" <<'SH'
#!/bin/sh
case "$1" in
  ps)
    printf 'bootstrap-agent\twoodpeckerci/woodpecker-agent:v3.19\tUp 5 minutes\n'
    ;;
  inspect)
    printf 'WOODPECKER_HOSTNAME=bootstrap-ci-1\n'
    printf 'WOODPECKER_BACKEND=docker\n'
    printf 'WOODPECKER_AGENT_SINGLE_WORKFLOW=false\n'
    printf 'WOODPECKER_MAX_WORKFLOWS=1\n'
    printf 'WOODPECKER_RETRY_TIMEOUT=0\n'
    case "${MOCK_LABEL_CASE:-legacy}" in
      legacy) printf 'WOODPECKER_LABELS=pool=bootstrap-ci,platform=linux/amd64\n';;
      wrong) printf 'WOODPECKER_AGENT_LABELS=pool=wrong,platform=linux/amd64\n';;
      correct) printf 'WOODPECKER_AGENT_LABELS=platform=linux/amd64,pool=bootstrap-ci\n';;
    esac
    ;;
esac
SH
chmod +x "$tmp/bin/docker"

if MOCK_OAUTH_CASE=healthy MOCK_LABEL_CASE=legacy diagnose >"$tmp/legacy-labels.out" 2>&1; then
  echo "FAIL: legacy WOODPECKER_LABELS incorrectly certified as schedulable" >&2
  exit 1
fi
if ! grep -q 'FAIL:.*WOODPECKER_AGENT_LABELS.*pool=bootstrap-ci' "$tmp/legacy-labels.out"; then
  echo "FAIL: legacy labels not explained as a bootstrap scheduling failure" >&2
  cat "$tmp/legacy-labels.out" >&2
  exit 1
fi
if MOCK_OAUTH_CASE=healthy MOCK_LABEL_CASE=wrong diagnose >"$tmp/wrong-labels.out" 2>&1; then
  echo "FAIL: unrelated agent pool incorrectly certified as bootstrap-ci" >&2
  exit 1
fi
if ! MOCK_OAUTH_CASE=healthy MOCK_LABEL_CASE=correct diagnose >"$tmp/correct-labels.out" 2>&1; then
  echo "FAIL: real bootstrap label rejected" >&2
  cat "$tmp/correct-labels.out" >&2
  exit 1
fi
echo "PASS: bootstrap agent label provenance distinguishes legacy, wrong, and correct configuration"
