#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Manage a small pool of official GitHub Actions repository runners on one Linux host.

Usage:
  runner-pool.sh install
  runner-pool.sh status
  runner-pool.sh remove

Required for all commands:
  REPO_URL            Repository URL, e.g. https://github.com/dporkka/apex

Required for install:
  RUNNER_TOKEN        Short-lived runner registration token from GitHub
  RUNNER_ARCHIVE      Path to the official actions-runner linux-x64 tarball
  RUNNER_SHA256       SHA-256 shown by GitHub for that runner archive

Required for remove:
  RUNNER_TOKEN        Short-lived runner removal token from GitHub

Optional:
  RUNNER_COUNT        Number of runners in the pool (default: 2)
  POOL_ROOT           Parent directory (default: $HOME/actions-runners)
  POOL_NAME           Pool directory name (default: <repo>-pool)
  RUNNER_NAME_PREFIX  Runner name prefix (default: <hostname>-<repo>)
  RUNNER_LABELS       Additional comma-separated labels; default labels remain enabled
  DELETE_RUNNER_DIRS  Set to true with remove to delete runner directories

The token is consumed only by config.sh and is never written by this script.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

[[ ${EUID:-$(id -u)} -ne 0 ]] || fail "run as the dedicated runner user, not root; sudo is used only for svc.sh"

command="${1:-}"
case "$command" in
  install|status|remove) ;;
  -h|--help|help|"") usage; exit 0 ;;
  *) usage >&2; fail "unknown command: $command" ;;
esac

require_env REPO_URL

RUNNER_COUNT="${RUNNER_COUNT:-2}"
[[ "$RUNNER_COUNT" =~ ^[1-9][0-9]*$ ]] || fail "RUNNER_COUNT must be a positive integer"

POOL_ROOT="${POOL_ROOT:-$HOME/actions-runners}"
repo_url="$REPO_URL"
repo_name="${repo_url##*/}"
repo_name="${repo_name%.git}"
[[ -n "$repo_name" && "$repo_name" != "$repo_url" ]] || fail "could not derive repository name from REPO_URL"

POOL_NAME="${POOL_NAME:-${repo_name}-pool}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-$(hostname -s)-${repo_name}}"
RUNNER_LABELS="${RUNNER_LABELS:-}"
pool_dir="$POOL_ROOT/$POOL_NAME"

runner_dir() {
  local index="$1"
  printf '%s/runner-%s' "$pool_dir" "$index"
}

status_pool() {
  local found=0
  local i dir
  for ((i = 1; i <= RUNNER_COUNT; i++)); do
    dir="$(runner_dir "$i")"
    if [[ -x "$dir/svc.sh" ]]; then
      found=1
      echo "==> ${RUNNER_NAME_PREFIX}-${i}"
      (cd "$dir" && sudo ./svc.sh status) || true
    else
      echo "==> ${RUNNER_NAME_PREFIX}-${i}: not installed ($dir)"
    fi
  done
  [[ "$found" -eq 1 ]] || return 1
}

install_pool() {
  require_env RUNNER_TOKEN
  require_env RUNNER_ARCHIVE
  require_env RUNNER_SHA256

  command -v tar >/dev/null || fail "tar is required"
  command -v sha256sum >/dev/null || fail "sha256sum is required"
  command -v sudo >/dev/null || fail "sudo is required to install runner services"
  [[ -f "$RUNNER_ARCHIVE" ]] || fail "runner archive not found: $RUNNER_ARCHIVE"

  local actual_sha
  actual_sha="$(sha256sum "$RUNNER_ARCHIVE" | awk '{print $1}')"
  [[ "$actual_sha" == "$RUNNER_SHA256" ]] || fail "runner archive SHA-256 mismatch"

  mkdir -p "$pool_dir"

  local i dir name
  local -a config_args
  for ((i = 1; i <= RUNNER_COUNT; i++)); do
    dir="$(runner_dir "$i")"
    name="${RUNNER_NAME_PREFIX}-${i}"

    if [[ -f "$dir/.runner" ]]; then
      echo "==> $name already configured; leaving it unchanged"
      continue
    fi

    [[ ! -e "$dir" || -z "$(ls -A "$dir" 2>/dev/null)" ]] || fail "$dir exists and is not an initialized runner; refusing to overwrite it"
    mkdir -p "$dir"
    tar -xzf "$RUNNER_ARCHIVE" -C "$dir"

    echo "==> configuring $name"
    config_args=(
      --unattended
      --url "$REPO_URL"
      --token "$RUNNER_TOKEN"
      --name "$name"
      --work _work
    )
    if [[ -n "$RUNNER_LABELS" ]]; then
      config_args+=(--labels "$RUNNER_LABELS")
    fi

    (
      cd "$dir"
      ./config.sh "${config_args[@]}"
      sudo ./svc.sh install "$USER"
      sudo ./svc.sh start
      sudo ./svc.sh status
    )
  done

  echo
  echo "Runner pool installed under: $pool_dir"
  echo "Expected GitHub default labels: self-hosted, Linux, X64"
}

remove_pool() {
  require_env RUNNER_TOKEN
  command -v sudo >/dev/null || fail "sudo is required to remove runner services"

  local i dir name
  for ((i = 1; i <= RUNNER_COUNT; i++)); do
    dir="$(runner_dir "$i")"
    name="${RUNNER_NAME_PREFIX}-${i}"
    [[ -d "$dir" ]] || continue

    echo "==> removing $name"
    (
      cd "$dir"
      if [[ -x ./svc.sh ]]; then
        sudo ./svc.sh stop || true
        sudo ./svc.sh uninstall || true
      fi
      if [[ -x ./config.sh && -f .runner ]]; then
        ./config.sh remove --token "$RUNNER_TOKEN"
      fi
    )

    if [[ "${DELETE_RUNNER_DIRS:-false}" == "true" ]]; then
      rm -rf -- "$dir"
    fi
  done
}

case "$command" in
  install) install_pool ;;
  status) status_pool ;;
  remove) remove_pool ;;
esac
