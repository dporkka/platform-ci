#!/usr/bin/env bash
set -Eeuo pipefail

server="${WOODPECKER_SERVER:-https://ci.adacavo.com}"
apply=0
restart_agent=0
restart_server=0

usage() {
  cat <<'USAGE'
Usage: recover-control-plane.sh [options]

Guarded Woodpecker control-plane recovery helper. Dry-run by default.

Options:
  --server URL        Public Woodpecker URL (default: https://ci.adacavo.com)
  --apply             Execute safe recovery actions instead of printing them
  --restart-agent     Restart running Woodpecker agent container(s) as well
  --restart-server    Restart running Woodpecker server container(s) as well
  -h, --help          Show this help

Default --apply behavior:
- restart cloudflared.service only when it is not active;
- start stopped Woodpecker containers;
- leave already-running Woodpecker server/agent containers untouched.

Use --restart-agent only when queued/pending work is not being claimed by an
otherwise-running agent. Use --restart-server only with stronger evidence that
the server process is unhealthy. Neither option changes repository configuration,
secrets, tunnel configuration, or Woodpecker repository settings.
USAGE
}

while (($#)); do
  case "$1" in
    --server)
      [[ $# -ge 2 ]] || { echo "--server requires a value" >&2; exit 2; }
      server="$2"; shift 2 ;;
    --apply) apply=1; shift ;;
    --restart-agent) restart_agent=1; shift ;;
    --restart-server) restart_server=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

server="${server%/}"

say() { printf '%s\n' "$*"; }
run() {
  if ((apply)); then
    say "+ $*"
    "$@"
  else
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  fi
}

say "Woodpecker recovery target: $server"
if ((apply)); then
  say "mode: APPLY"
else
  say "mode: DRY RUN (pass --apply to execute)"
fi

say
say "== cloudflared user service =="
if command -v systemctl >/dev/null 2>&1; then
  if systemctl --user is-active --quiet cloudflared.service; then
    say "cloudflared.service is active; leaving it running"
  else
    say "cloudflared.service is not active"
    run systemctl --user restart cloudflared.service
  fi
else
  say "WARN: systemctl unavailable; cannot manage cloudflared.service" >&2
fi

runtime=""
if command -v podman >/dev/null 2>&1; then
  runtime="podman"
elif command -v docker >/dev/null 2>&1; then
  runtime="docker"
fi

say
say "== Woodpecker containers =="
if [[ -z "$runtime" ]]; then
  say "WARN: neither podman nor docker is available" >&2
else
  mapfile -t rows < <($runtime ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null | grep -i woodpecker || true)
  if ((${#rows[@]} == 0)); then
    say "WARN: no Woodpecker containers found via $runtime" >&2
  fi

  for row in "${rows[@]}"; do
    IFS='|' read -r name image status <<<"$row"
    say "$name | $image | $status"

    lower="$(printf '%s %s' "$name" "$image" | tr '[:upper:]' '[:lower:]')"
    is_agent=0
    is_server=0
    [[ "$lower" == *agent* ]] && is_agent=1
    [[ "$lower" == *server* ]] && is_server=1

    if [[ "$status" != Up* && "$status" != Running* ]]; then
      run "$runtime" start "$name"
      continue
    fi

    if ((is_agent && restart_agent)); then
      run "$runtime" restart "$name"
    elif ((is_server && restart_server)); then
      run "$runtime" restart "$name"
    fi
  done
fi

say
say "== post-recovery health =="
if ((apply)); then
  if command -v curl >/dev/null 2>&1; then
    code="$(curl -sS -o /tmp/woodpecker-health.$$ -w '%{http_code}' --connect-timeout 5 --max-time 10 "$server/healthz" || true)"
    rm -f /tmp/woodpecker-health.$$
    if [[ "$code" == "204" ]]; then
      say "OK: $server/healthz returned 204"
    else
      say "WARN: $server/healthz returned ${code:-unreachable}" >&2
    fi
  else
    say "WARN: curl unavailable; skipping public health check" >&2
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user --no-pager --full status cloudflared.service || true
  fi

  if [[ -n "$runtime" ]]; then
    $runtime ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -i woodpecker || true
  fi
else
  say "No changes made. Re-run with --apply after reviewing the dry-run output."
fi
