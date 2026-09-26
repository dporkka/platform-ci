#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/woodpecker/scripts/recover-control-plane.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKEBIN="$TMP/bin"
mkdir -p "$FAKEBIN"

cat >"$FAKEBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "--user is-active --quiet cloudflared.service")
    exit 0
    ;;
  "--user restart cloudflared.service")
    printf 'restart\n' >>"$CALL_LOG"
    exit 0
    ;;
  "--user --no-pager --full status cloudflared.service")
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

cat >"$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '204'
EOF

chmod +x "$FAKEBIN/systemctl" "$FAKEBIN/curl"

export PATH="$FAKEBIN:/usr/bin:/bin"
export CALL_LOG="$TMP/calls.log"

: >"$CALL_LOG"
bash "$SCRIPT" --server https://ci.adacavo.com --apply >/dev/null
if grep -Fx 'restart' "$CALL_LOG" >/dev/null; then
  printf 'FAIL: active tunnel restarted without explicit request\n' >&2
  exit 1
fi

: >"$CALL_LOG"
bash "$SCRIPT" --server https://ci.adacavo.com --apply --restart-tunnel >/dev/null
grep -Fx 'restart' "$CALL_LOG" >/dev/null || {
  printf 'FAIL: --restart-tunnel did not restart an active cloudflared service\n' >&2
  exit 1
}

printf 'Woodpecker tunnel recovery behavior is guarded.\n'
