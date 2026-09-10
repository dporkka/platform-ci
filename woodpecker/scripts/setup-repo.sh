#!/usr/bin/env sh
# ──────────────────────────────────────────────────────────────────────────────
# setup-repo.sh — shared dependency bootstrap for Woodpecker pipelines
#
# This is the single copy of the Node/pnpm bootstrap for every repository on the
# self-hosted Woodpecker instance. Pipelines download it into the workspace as
# the first step (`Bootstrap`) and source it from there. The project it installs
# is the **current directory**, so a package in a subdirectory is handled by
# changing directory first:
#
#   - . .woodpecker/scripts/setup-repo.sh                        # repo root
#   - cd apps/web && . ../.woodpecker/scripts/setup-repo.sh      # subdirectory
#
# Do not pass a path as an argument: dash — the `/bin/sh` of Debian-based images
# and therefore Woodpecker's step shell — does not pass operands to a sourced
# script, so `$1` arrives empty and the install would run in the workspace root.
# `SETUP_PROJECT` (path relative to the workspace) is the explicit alternative.
#
# It must be sourced (leading dot), not executed: Woodpecker runs each step in a
# fresh container, so the exports below only reach the remaining commands of the
# *same* step if they happen in that step's shell. Because the file is sourced,
# its shebang is ignored — it must therefore survive dash (`/bin/sh`), which is
# what Woodpecker uses to run step commands: no `[[ ]]`, no arrays, no `local`,
# no `set -o pipefail`.
#
# State that must outlive a single step lives inside the workspace volume, which
# Woodpecker mounts into every step of the workflow:
#   <project>/node_modules                   installed dependencies
#   $CI_WORKSPACE/.woodpecker/corepack       corepack download cache
# The pnpm content-addressable store should be a separate named volume mounted
# at /root/.local/share/pnpm/store (see the templates' step definitions).
#
# `pnpm install` is guarded by a stamp keyed on the project's lockfile, so only
# the first step of a pipeline pays for it; later steps reuse the workspace.
#
# Environment overrides:
#   PNPM_VERSION   pnpm version to activate (default 10.22.0)
#   CI_WORKSPACE   workspace root Woodpecker mounts (default $PWD)
#   SETUP_PROJECT  project to install, relative to the workspace (default $PWD)
# ──────────────────────────────────────────────────────────────────────────────
set -eu

WORKSPACE="${CI_WORKSPACE:-$PWD}"
PROJECT="${SETUP_PROJECT:-$PWD}"

case "$PROJECT" in
  /*) ;;
  *) PROJECT="$WORKSPACE/$PROJECT" ;;
esac

PNPM_VERSION="${PNPM_VERSION:-10.22.0}"

COREPACK_HOME="$WORKSPACE/.woodpecker/corepack"
TURBO_TELEMETRY_DISABLED=1
DO_NOT_TRACK=1
export COREPACK_HOME TURBO_TELEMETRY_DISABLED DO_NOT_TRACK
mkdir -p "$COREPACK_HOME"

# Shims are recreated per step (cheap, /usr/local/bin is already on PATH); the
# pnpm version itself is downloaded into COREPACK_HOME and therefore cached.
# Fall back to a workspace-local bin dir when /usr/local/bin is not writable.
if ! corepack enable --install-directory /usr/local/bin >/dev/null 2>&1; then
  mkdir -p "$WORKSPACE/.woodpecker/bin"
  corepack enable --install-directory "$WORKSPACE/.woodpecker/bin" >/dev/null
  PATH="$WORKSPACE/.woodpecker/bin:$PATH"
  export PATH
fi
corepack prepare "pnpm@$PNPM_VERSION" --activate >/dev/null

# The stamp key is the hash of the project's lockfile. Repositories without a
# committed lockfile (installed with --no-frozen-lockfile) key on package.json
# instead, so a dependency edit still invalidates the stamp.
LOCKFILE=""
for candidate in pnpm-lock.yaml bun.lock package-lock.json; do
  if [ -f "$PROJECT/$candidate" ]; then
    LOCKFILE="$PROJECT/$candidate"
    break
  fi
done

if [ -n "$LOCKFILE" ]; then
  STAMP_KEY="$(sha256sum "$LOCKFILE" | cut -c1-16)"
  STAMP_PREFIX=".woodpecker-lock-"
  case "$LOCKFILE" in
    */pnpm-lock.yaml)
      FROZEN="--frozen-lockfile"
      GENERATES_LOCK=""
      ;;
    *)
      # pnpm cannot install from a foreign lockfile; it resolves and writes
      # pnpm-lock.yaml, which is removed again below.
      FROZEN="--no-frozen-lockfile"
      GENERATES_LOCK="1"
      ;;
  esac
else
  STAMP_KEY="$(sha256sum "$PROJECT/package.json" | cut -c1-16)"
  STAMP_PREFIX=".woodpecker-deps-"
  FROZEN="--no-frozen-lockfile"
  GENERATES_LOCK="1"
fi

STAMP="$PROJECT/node_modules/$STAMP_PREFIX$STAMP_KEY"

if [ ! -f "$STAMP" ]; then
  pnpm --dir "$PROJECT" install "$FROZEN"
  # Drop the resolved lockfile when the project does not commit one: it is a
  # workspace artifact, and leaving it behind would flip the stamp key on the
  # next step (forcing a second install) and dirty the checkout for pipelines
  # that assert a clean tree.
  if [ -n "${GENERATES_LOCK:-}" ]; then
    rm -f "$PROJECT/pnpm-lock.yaml"
  fi
  # Drop stamps from previous installs so a stale node_modules is never reused.
  rm -f "$PROJECT"/node_modules/.woodpecker-lock-* 2>/dev/null || true
  rm -f "$PROJECT"/node_modules/.woodpecker-deps-* 2>/dev/null || true
  mkdir -p "$PROJECT/node_modules"
  touch "$STAMP"
fi
