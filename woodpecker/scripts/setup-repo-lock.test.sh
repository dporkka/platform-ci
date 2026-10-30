#!/usr/bin/env bash
# Regression for the flock-less bootstrap used on minimal CI images.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP="$ROOT/woodpecker/scripts/setup-repo.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
WORK="$TMP/work"
BINS="$TMP/bin"
mkdir -p "$WORK/.woodpecker" "$BINS"
printf '{"name":"bootstrap-lock-test"}\n' > "$WORK/package.json"
for utility in sha256sum cut mkdir touch rm rmdir; do
  ln -s "$(command -v "$utility")" "$BINS/$utility"
done
# Scripts intentionally omit flock. Sleep is made instantaneous so the bounded
# timeout is covered by a fast deterministic test.
printf '#!/bin/sh\nexit 0\n' > "$BINS/corepack"
printf '#!/bin/sh\nexit 0\n' > "$BINS/sleep"
printf '#!/bin/sh\nprintf "install\\n" >> "$BOOTSTRAP_TEST_LOG"\n' > "$BINS/pnpm"
chmod +x "$BINS/corepack" "$BINS/sleep" "$BINS/pnpm"
if [ -e "$BINS/flock" ]; then echo 'unexpected flock shim' >&2; exit 1; fi

# Simulate another agent holding a mkdir fallback lock indefinitely. The
# bootstrap must fail closed, must not invoke pnpm, and must not remove that
# other agent's lock directory.
mkdir "$WORK/.woodpecker/install.lock.d"
set +e
CI_WORKSPACE="$WORK" SETUP_PROJECT="$WORK" BOOTSTRAP_TEST_LOG="$TMP/installs" PATH="$BINS" \
  /bin/sh -c '. "$1"' sh "$BOOTSTRAP" > "$TMP/out" 2> "$TMP/err"
code=$?
set -e
if [ "$code" -eq 0 ]; then echo 'FAIL: stale lock allowed an install' >&2; exit 1; fi
grep -q 'lock timed out' "$TMP/err" || { echo 'FAIL: no safe timeout diagnosis' >&2; exit 1; }
[ -d "$WORK/.woodpecker/install.lock.d" ] || { echo 'FAIL: foreign lock removed' >&2; exit 1; }
[ ! -e "$TMP/installs" ] || { echo 'FAIL: pnpm was called without lock' >&2; exit 1; }

# A free mkdir fallback lock must still allow exactly one install and release.
rmdir "$WORK/.woodpecker/install.lock.d"
CI_WORKSPACE="$WORK" SETUP_PROJECT="$WORK" BOOTSTRAP_TEST_LOG="$TMP/installs" PATH="$BINS" \
  /bin/sh -c '. "$1"' sh "$BOOTSTRAP" > "$TMP/out2" 2> "$TMP/err2"
[ ! -d "$WORK/.woodpecker/install.lock.d" ] || { echo 'FAIL: lock not released' >&2; exit 1; }
[ "$(wc -l < "$TMP/installs")" -eq 1 ] || { echo 'FAIL: expected one install' >&2; exit 1; }
echo 'PASS: mkdir fallback lock fails closed and single installer owns release'
