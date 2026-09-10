#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# notify-slack.sh — shared Slack failure notification for Woodpecker pipelines
#
# Usage: .woodpecker/scripts/notify-slack.sh "<context label>" [run-url]
#
# No-op when SLACK_WEBHOOK_URL is unset, so a pipeline that references it keeps
# working on repositories (and events) where no webhook secret is configured.
# Intended as the last step of a secret-bearing pipeline with
# `when: [{status: [failure]}]`.
#
# Requires bash, curl and node (JSON encoding); all are present in
# node:22-bookworm. Steps on images without bash must invoke it explicitly:
#
#   - entrypoint: ["/bin/bash", "-c", "echo $CI_SCRIPT | base64 -d | /bin/bash -e"]
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONTEXT="${1:?usage: notify-slack.sh <context label> [run-url]}"
RUN_URL="${2:-${CI_PIPELINE_URL:-}}"
BRANCH="${CI_COMMIT_BRANCH:-${CI_COMMIT_TAG:-unknown}}"

if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
  echo "SLACK_WEBHOOK_URL is not set; skipping Slack notification."
  exit 0
fi

PAYLOAD="$(node -e '
  const [context, runUrl, branch, number] = process.argv.slice(1);
  const link = runUrl ? `<${runUrl}|pipeline #${number}>` : `pipeline #${number}`;
  process.stdout.write(JSON.stringify({ text: `:x: *${context}* failed — ${link} on \`${branch}\`` }));
' "$CONTEXT" "$RUN_URL" "$BRANCH" "${CI_PIPELINE_NUMBER:-?}")"

curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
  -d "$PAYLOAD" "$SLACK_WEBHOOK_URL" || echo "Slack notification failed"
