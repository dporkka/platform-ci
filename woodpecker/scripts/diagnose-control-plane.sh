#!/usr/bin/env bash
set -Eeuo pipefail

server="${WOODPECKER_SERVER:-https://ci.adacavo.com}"
repo="${WOODPECKER_REPO:-dporkka/apex}"
repair_webhook=0
show_logs=0
log_since="${WOODPECKER_LOG_SINCE:-30m}"
pipeline=""

usage() {
  cat <<'USAGE'
Usage: diagnose-control-plane.sh [options]

Read-only Woodpecker control-plane diagnostics by default.

Options:
  --server URL          Woodpecker public URL (default: $WOODPECKER_SERVER or https://ci.adacavo.com)
  --repo OWNER/NAME     Repository to look for (default: $WOODPECKER_REPO or dporkka/apex)
  --logs                Print recent Woodpecker container logs (may contain operational metadata)
  --log-since DURATION  Container log window (default: 30m)
  --pipeline NUMBER      Inspect one exact pipeline and its step states
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
    --pipeline)
      [[ $# -ge 2 ]] || { echo "--pipeline requires a numeric pipeline number" >&2; exit 2; }
      [[ "$2" =~ ^[0-9]+$ ]] || { echo "--pipeline requires a numeric pipeline number" >&2; exit 2; }
      pipeline="$2"; shift 2 ;;
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
cloudflare_1033=0

section() { printf '\n== %s ==\n' "$1"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; warnings=$((warnings + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

container_env_value() {
  local runtime="$1"
  local name="$2"
  local key="$3"
  "$runtime" inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null \
    | awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

section "configuration"
printf 'server: %s\nrepo:   %s\n' "$server" "$repo"
if [[ -n "$pipeline" ]]; then
  printf 'pipeline: %s\n' "$pipeline"
fi

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
    if grep -Eqi 'Error[[:space:]]+1033|Cloudflare Tunnel error' "$body_file" 2>/dev/null; then
      cloudflare_1033=1
      fail "$server/healthz is behind Cloudflare but no healthy tunnel connector is available (Error 1033)"
    else
      fail "$server/healthz returned HTTP $http_code"
    fi
    if [[ -s "$body_file" ]]; then
      sed -n '1,20p' "$body_file"
    fi
  fi
else
  warn "curl is unavailable; skipping HTTP health check"
fi

if ((cloudflare_1033)); then
  section "cloudflare tunnel"
  echo "Cloudflare Error 1033 means the edge cannot reach an active connector for this tunnel."

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user is-active --quiet cloudflared.service 2>/dev/null; then
      ok "cloudflared.service is active for the current user"
      warn "the service is active but Cloudflare still reports 1033; inspect connector logs and token/tunnel health"
    else
      fail "cloudflared.service is not active for the current user"
    fi

    if systemctl --user show cloudflared.service >/dev/null 2>&1; then
      systemctl --user show cloudflared.service \
        --property=ActiveState,SubState,ExecMainStatus,Result \
        --no-pager 2>/dev/null || true
    else
      warn "cloudflared.service is not installed in the current user's systemd manager"
    fi
  else
    warn "systemctl is unavailable; cannot inspect the local cloudflared user service"
  fi

  tunnel_env="$HOME/.config/cloudflared/ci-adacavo.env"
  if [[ -r "$tunnel_env" ]]; then
    ok "$tunnel_env exists and is readable (contents intentionally not printed)"
  else
    warn "$tunnel_env is missing or unreadable on this host"
  fi

  if command -v loginctl >/dev/null 2>&1; then
    linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)"
    if [[ "$linger" == "yes" ]]; then
      ok "systemd user lingering is enabled for $USER"
    elif [[ -n "$linger" ]]; then
      warn "systemd user lingering is $linger for $USER; tunnel service may stop after logout"
    fi
  fi

  cat <<EOF_RECOVERY
Recovery commands to run on the CI workstation after confirming the service belongs to this tunnel:
  systemctl --user restart cloudflared.service
  systemctl --user status cloudflared.service --no-pager
  journalctl --user -u cloudflared.service --since "$log_since" --no-pager | tail -n 200
Then rerun this diagnostic and require $server/healthz to return HTTP 204.
EOF_RECOVERY
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

  if [[ -n "$pipeline" ]]; then
    section "pipeline $pipeline"

    pipeline_info=""
    if pipeline_info="$(woodpecker-cli --server "$server" pipeline show "$repo" "$pipeline" 2>&1)"; then
      ok "pipeline $pipeline metadata is readable"
      printf '%s\n' "$pipeline_info"
    else
      fail "could not read pipeline $pipeline metadata for $repo"
      printf '%s\n' "$pipeline_info" >&2
    fi

    pipeline_steps=""
    if pipeline_steps="$(woodpecker-cli --server "$server" pipeline ps "$repo" "$pipeline" 2>&1)"; then
      ok "pipeline $pipeline step state is readable"
      printf '%s\n' "$pipeline_steps"
    else
      fail "could not read pipeline $pipeline steps for $repo"
      printf '%s\n' "$pipeline_steps" >&2
    fi

    if ((show_logs)); then
      pipeline_logs=""
      if pipeline_logs="$(woodpecker-cli --server "$server" pipeline log show "$repo" "$pipeline" 2>&1)"; then
        ok "pipeline $pipeline logs are readable"
        printf '%s\n' "$pipeline_logs" | tail -n 400
      else
        warn "could not read pipeline $pipeline logs for $repo"
        printf '%s\n' "$pipeline_logs" >&2
      fi
    fi
  fi
else
  warn "woodpecker-cli is unavailable; install it or run this script on the CI host"
fi

section "local containers"
runtimes=()
for candidate in docker podman; do
  if command -v "$candidate" >/dev/null 2>&1; then
    runtimes+=("$candidate")
  fi
done

if ((${#runtimes[@]} > 0)); then
  found=0
  for runtime in "${runtimes[@]}"; do
    containers="$("$runtime" ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | grep -i woodpecker || true)"
    if [[ -z "$containers" ]]; then
      warn "no local containers with 'woodpecker' in name/image were found via $runtime"
      continue
    fi
    found=1
    printf '\n-- %s --\n' "$runtime"
    printf '%s\n' "$containers"
    while IFS=$'\t' read -r name image status; do
      [[ -n "$name" ]] || continue
      if [[ "$status" == Up* || "$status" == Running* ]]; then
        ok "$runtime:$name is running ($image)"
      else
        fail "$runtime:$name is not running: $status"
      fi

      lower_identity="$(printf '%s %s' "$name" "$image" | tr '[:upper:]' '[:lower:]')"
      if [[ "$lower_identity" == *agent* ]]; then
        agent_hostname="$(container_env_value "$runtime" "$name" WOODPECKER_HOSTNAME || true)"
        agent_backend="$(container_env_value "$runtime" "$name" WOODPECKER_BACKEND || true)"
        agent_single="$(container_env_value "$runtime" "$name" WOODPECKER_AGENT_SINGLE_WORKFLOW || true)"
        agent_capacity="$(container_env_value "$runtime" "$name" WOODPECKER_MAX_WORKFLOWS || true)"
        agent_retry="$(container_env_value "$runtime" "$name" WOODPECKER_RETRY_TIMEOUT || true)"

        printf '  agent hostname=%s backend=%s single_workflow=%s max_workflows=%s retry_timeout=%s\n' \
          "${agent_hostname:-unset}" "${agent_backend:-unset}" "${agent_single:-unset}" \
          "${agent_capacity:-unset}" "${agent_retry:-unset}"

        if [[ "$agent_hostname" == "bootstrap-ci-1" ]]; then
          ok "$runtime:$name uses the stable bootstrap-ci-1 identity"
        else
          warn "$runtime:$name is a Woodpecker agent but does not advertise WOODPECKER_HOSTNAME=bootstrap-ci-1"
        fi
        [[ "$agent_backend" == "docker" ]] || warn "$runtime:$name does not explicitly use WOODPECKER_BACKEND=docker"
        [[ "$agent_single" == "true" ]] || warn "$runtime:$name is not in single-workflow self-refresh mode"
        [[ "$agent_capacity" == "1" ]] || warn "$runtime:$name does not have WOODPECKER_MAX_WORKFLOWS=1"
        [[ "$agent_retry" == "0" ]] || warn "$runtime:$name does not have infinite server reconnect (WOODPECKER_RETRY_TIMEOUT=0)"
      fi

      if ((show_logs)); then
        printf '\n-- %s:%s logs since %s --\n' "$runtime" "$name" "$log_since"
        "$runtime" logs --since "$log_since" "$name" 2>&1 | tail -n 200 || true
      fi
    done <<< "$containers"
  done
  if ((found == 0)); then
    warn "no Woodpecker containers found in installed container runtimes"
  fi
else
  warn "neither docker nor podman is available; skipping local container checks"
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
