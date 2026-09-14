#!/usr/bin/env bash
set -Eeuo pipefail

server="${WOODPECKER_SERVER:-https://ci.adacavo.com}"
repo="${WOODPECKER_REPO:-dporkka/apex}"
repair_webhook=0
show_logs=0
log_since="${WOODPECKER_LOG_SINCE:-30m}"

usage() {
  cat <<'USAGE'
Usage: diagnose-control-plane.sh [options]

Read-only Woodpecker control-plane diagnostics by default.

Options:
  --server URL          Woodpecker public URL (default: $WOODPECKER_SERVER or https://ci.adacavo.com)
  --repo OWNER/NAME     Repository to look for (default: $WOODPECKER_REPO or dporkka/apex)
  --logs                Print recent Woodpecker container logs (may contain operational metadata)
  --log-since DURATION  Container log window (default: 30m)
  --repair-webhook      Run `woodpecker-cli repo repair OWNER/NAME` after diagnostics
  -h, --help            Show this help

Authentication for CLI checks is taken from the normal woodpecker-cli context,
WOODPECKER_TOKEN, or the OS keyring. The script never prints token values.
USAGE
}

while (($#)); do
  case "$1" in
    --server)
      [[ $# -ge 2 ]] || { echo "--server requires a value" >&2; exit 2; }
      server="$2"; shift 2 ;;
    --repo)
      [[ $# -ge 2 ]] || { echo "--repo requires a value" >&2; exit 2; }
      repo="$2"; shift 2 ;;
    --logs) show_logs=1; shift ;;
    --log-since)
      [[ $# -ge 2 ]] || { echo "--log-since requires a value" >&2; exit 2; }
      log_since="$2"; shift 2 ;;
    --repair-webhook) repair_webhook=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

server="${server%/}"
host="${server#*://}"
host="${host%%/*}"
host="${host%%:*}"

failures=0
warnings=0

section() { printf '\n== %s ==\n' "$1"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; warnings=$((warnings + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

section "configuration"
printf 'server: %s\nrepo:   %s\n' "$server" "$repo"

section "name resolution"
if command -v getent >/dev/null 2>&1; then
  if getent ahosts "$host" | head -n 5; then
    ok "$host resolves"
  else
    fail "$host does not resolve from this host"
  fi
else
  warn "getent is unavailable; skipping explicit DNS check"
fi

section "server health"
if command -v curl >/dev/null 2>&1; then
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' EXIT
  http_code="$(curl -sS -o "$body_file" -w '%{http_code}' --connect-timeout 5 --max-time 10 "$server/healthz" || true)"
  if [[ "$http_code" == "204" ]]; then
    ok "$server/healthz returned 204"
  elif [[ -z "$http_code" || "$http_code" == "000" ]]; then
    fail "$server/healthz is unreachable"
  else
    fail "$server/healthz returned HTTP $http_code"
    if [[ -s "$body_file" ]]; then
      sed -n '1,20p' "$body_file"
    fi
  fi
else
  warn "curl is unavailable; skipping HTTP health check"
fi

section "woodpecker cli"
if command -v woodpecker-cli >/dev/null 2>&1; then
  info_file="$(mktemp)"
  if woodpecker-cli --server "$server" info >"$info_file" 2>&1; then
    ok "authenticated CLI request succeeded"
    sed -n '1,10p' "$info_file"
  else
    warn "woodpecker-cli could not authenticate or reach the server"
    sed -n '1,20p' "$info_file" >&2 || true
  fi
  rm -f "$info_file"

  if repos="$(woodpecker-cli --server "$server" repo ls --all 2>&1)"; then
    if printf '%s\n' "$repos" | grep -F "$repo" >/dev/null; then
      ok "$repo is present in Woodpecker repository inventory"
      printf '%s\n' "$repos" | grep -F "$repo" | head -n 5
    else
      fail "$repo is missing from Woodpecker repository inventory"
    fi
  else
    warn "could not list Woodpecker repositories"
    printf '%s\n' "$repos" >&2
  fi

  if queue="$(woodpecker-cli --server "$server" pipeline queue 2>&1)"; then
    if [[ -n "$queue" ]]; then
      printf '%s\n' "$queue"
      if printf '%s\n' "$queue" | grep -F "$repo" >/dev/null; then
        warn "$repo has queued Woodpecker work; inspect agent connectivity/capacity"
      else
        ok "no queued entry for $repo"
      fi
    else
      ok "Woodpecker queue is empty"
    fi
  else
    warn "could not inspect Woodpecker pipeline queue"
    printf '%s\n' "$queue" >&2
  fi
else
  warn "woodpecker-cli is unavailable; install it or run this script on the CI host"
fi

section "local containers"
runtime=""
if command -v podman >/dev/null 2>&1; then
  runtime="podman"
elif command -v docker >/dev/null 2>&1; then
  runtime="docker"
fi

if [[ -n "$runtime" ]]; then
  containers="$($runtime ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | grep -i woodpecker || true)"
  if [[ -n "$containers" ]]; then
    printf '%s\n' "$containers"
    while IFS=$'\t' read -r name image status; do
      [[ -n "$name" ]] || continue
      if [[ "$status" == Up* || "$status" == Running* ]]; then
        ok "$name is running ($image)"
      else
        fail "$name is not running: $status"
      fi
      if ((show_logs)); then
        printf '\n-- %s logs since %s --\n' "$name" "$log_since"
        $runtime logs --since "$log_since" "$name" 2>&1 | tail -n 200 || true
      fi
    done <<< "$containers"
  else
    warn "no local containers with 'woodpecker' in name/image were found via $runtime"
  fi
else
  warn "neither podman nor docker is available; skipping local container checks"
fi

if ((repair_webhook)); then
  section "webhook repair"
  if ! command -v woodpecker-cli >/dev/null 2>&1; then
    fail "--repair-webhook requires woodpecker-cli"
  else
    echo "Repairing Woodpecker's forge webhook for $repo ..."
    if woodpecker-cli --server "$server" repo repair "$repo"; then
      ok "webhook repair command completed"
    else
      fail "webhook repair failed"
    fi
  fi
fi

section "result"
printf 'failures: %d\nwarnings: %d\n' "$failures" "$warnings"
if ((failures > 0)); then
  exit 1
fi
