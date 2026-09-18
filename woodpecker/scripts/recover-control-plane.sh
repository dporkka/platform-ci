#!/usr/bin/env bash
set -Eeuo pipefail

server="${WOODPECKER_SERVER:-https://ci.adacavo.com}"
apply=0
restart_agent=0
restart_server=0
start_containers=()
expected_agent_hostname="bootstrap-ci-1"

usage() {
  cat <<'USAGE'
Usage: recover-control-plane.sh [options]

Guarded Woodpecker control-plane recovery helper. Dry-run by default.

Options:
  --server URL                   Public Woodpecker URL (default: https://ci.adacavo.com)
  --apply                        Execute requested recovery actions instead of printing them
  --restart-agent                Restart only the stable bootstrap-ci-1 agent
  --restart-server               Restart running Woodpecker server container(s)
  --start-container RUNTIME:NAME Start one explicitly named stopped container; repeatable
  -h, --help                     Show this help

Default --apply behavior:
- restart cloudflared.service only when it is not active;
- inspect both Docker and Podman when installed;
- report stopped Woodpecker containers without starting them automatically;
- leave already-running Woodpecker server/agent containers untouched.

Use --restart-agent only when queued/pending work is not being claimed by the
otherwise-running stable bootstrap agent. It will only restart a container whose
WOODPECKER_HOSTNAME is exactly bootstrap-ci-1; legacy/ambiguous agent containers
are never restarted by this flag. Use --restart-server only with stronger evidence
that the server process is unhealthy. Use --start-container only after identifying
the intended stopped instance from the dry-run/diagnostic output.

No option changes repository configuration, secrets, tunnel configuration, or
Woodpecker repository settings.
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
    --start-container)
      [[ $# -ge 2 ]] || { echo "--start-container requires RUNTIME:NAME" >&2; exit 2; }
      start_containers+=("$2"); shift 2 ;;
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

container_env_value() {
  local runtime="$1"
  local name="$2"
  local key="$3"
  "$runtime" inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null \
    | awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

say "Woodpecker recovery target: $server"
if ((apply)); then
  say "mode: APPLY"
else
  say "mode: DRY RUN (pass --apply to execute requested actions)"
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

runtimes=()
for candidate in docker podman; do
  if command -v "$candidate" >/dev/null 2>&1; then
    runtimes+=("$candidate")
  fi
done

say
say "== explicit stopped-container starts =="
if ((${#start_containers[@]} == 0)); then
  say "none requested"
else
  for ref in "${start_containers[@]}"; do
    if [[ "$ref" != *:* ]]; then
      say "ERROR: --start-container must use RUNTIME:NAME, got '$ref'" >&2
      exit 2
    fi
    runtime="${ref%%:*}"
    name="${ref#*:}"
    if [[ "$runtime" != "docker" && "$runtime" != "podman" ]]; then
      say "ERROR: unsupported runtime '$runtime' in '$ref'" >&2
      exit 2
    fi
    if ! command -v "$runtime" >/dev/null 2>&1; then
      say "ERROR: requested runtime '$runtime' is not installed" >&2
      exit 1
    fi
    if ! "$runtime" ps -a --format '{{.Names}}' 2>/dev/null | grep -Fx -- "$name" >/dev/null; then
      say "ERROR: container '$name' not found in $runtime" >&2
      exit 1
    fi
    run "$runtime" start "$name"
  done
fi

say
say "== Woodpecker containers =="
if ((${#runtimes[@]} == 0)); then
  say "WARN: neither docker nor podman is available" >&2
else
  found=0
  stable_agent_found=0
  for runtime in "${runtimes[@]}"; do
    mapfile -t rows < <("$runtime" ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null | grep -i woodpecker || true)
    if ((${#rows[@]} == 0)); then
      say "$runtime: no Woodpecker containers found"
      continue
    fi
    found=1
    for row in "${rows[@]}"; do
      IFS='|' read -r name image status <<<"$row"
      say "$runtime:$name | $image | $status"

      lower="$(printf '%s %s' "$name" "$image" | tr '[:upper:]' '[:lower:]')"
      is_agent=0
      is_server=0
      [[ "$lower" == *agent* ]] && is_agent=1
      [[ "$lower" == *server* ]] && is_server=1

      if [[ "$status" != Up* && "$status" != Running* ]]; then
        say "  stopped; not starting automatically (use --start-container $runtime:$name after verification)"
        continue
      fi

      if ((is_agent)); then
        agent_hostname="$(container_env_value "$runtime" "$name" WOODPECKER_HOSTNAME || true)"
        if [[ "$agent_hostname" == "$expected_agent_hostname" ]]; then
          stable_agent_found=1
          say "  stable bootstrap agent identity confirmed: $agent_hostname"
          if ((restart_agent)); then
            run "$runtime" restart "$name"
          fi
        else
          say "  agent identity is '${agent_hostname:-unset}', not '$expected_agent_hostname'; leaving it untouched"
        fi
      fi

      if ((is_server && restart_server)); then
        run "$runtime" restart "$name"
      fi
    done
  done
  if ((found == 0)); then
    say "WARN: no Woodpecker containers found in installed runtimes" >&2
  fi
  if ((restart_agent && stable_agent_found == 0)); then
    say "ERROR: --restart-agent requested, but no running Woodpecker agent advertises WOODPECKER_HOSTNAME=$expected_agent_hostname" >&2
    say "Reconcile the canonical bootstrap deployment before touching legacy/ambiguous agents." >&2
    exit 1
  fi
fi

say
say "== post-recovery health =="
if ((apply)); then
  if command -v curl >/dev/null 2>&1; then
    health_file="$(mktemp)"
    code="$(curl -sS -o "$health_file" -w '%{http_code}' --connect-timeout 5 --max-time 10 "$server/healthz" || true)"
    rm -f "$health_file"
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

  for runtime in "${runtimes[@]}"; do
    "$runtime" ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | grep -i woodpecker || true
  done
else
  say "No changes made. Re-run with --apply after reviewing the dry-run output."
fi
