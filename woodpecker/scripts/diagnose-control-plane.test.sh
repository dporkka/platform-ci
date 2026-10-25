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
echo "PASS: exact pipeline diagnosis fails closed; generic health remains usable"
