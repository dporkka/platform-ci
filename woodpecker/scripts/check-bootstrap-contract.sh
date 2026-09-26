#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for template in woodpecker/templates/*.yml; do
  grep -Fq 'platform: linux/amd64' "$template" ||
    fail "$template must request platform: linux/amd64"
  grep -Fq 'pool: bootstrap-ci' "$template" ||
    fail "$template must request pool: bootstrap-ci"
done

if grep -Fq 'WOODPECKER_AGENT_SINGLE_WORKFLOW=true' woodpecker/CONTROL_PLANE.md; then
  fail 'CONTROL_PLANE.md must not recommend one-shot agent mode'
fi

if grep -Fq '[[ "$agent_single" == "true" ]]' woodpecker/scripts/diagnose-control-plane.sh; then
  fail 'diagnostics must not require one-shot agent mode'
fi

grep -Fq 'false/unset' woodpecker/CONTROL_PLANE.md ||
  fail 'CONTROL_PLANE.md must document persistent-agent single-workflow state'

grep -Fq 'pool: bootstrap-ci' woodpecker/README.md ||
  fail 'Woodpecker README must document mandatory bootstrap routing'

bash woodpecker/scripts/recover-control-plane.test.sh

printf 'Woodpecker bootstrap contract is internally consistent.\n'
