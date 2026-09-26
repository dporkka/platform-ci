#!/usr/bin/env bash
set -euo pipefail

repo="${1:-}"
target_pipeline="${2:-}"

if [[ -z "$repo" ]]; then
  echo "usage: $0 OWNER/NAME [PIPELINE]" >&2
  exit 2
fi
if [[ -n "$target_pipeline" && ! "$target_pipeline" =~ ^[0-9]+$ ]]; then
  echo "PIPELINE must be numeric" >&2
  exit 2
fi

queue_depth=0
repo_queue_depth=0
target_position="not-found"

while IFS='|' read -r full_name number status commit rest; do
  [[ -n "$full_name" ]] || continue
  queue_depth=$((queue_depth + 1))

  if [[ "$full_name" == "$repo" ]]; then
    repo_queue_depth=$((repo_queue_depth + 1))
    if [[ -n "$target_pipeline" && "$number" == "$target_pipeline" && "$target_position" == "not-found" ]]; then
      target_position="$queue_depth"
    fi
  fi
done

classification=""
if ((queue_depth == 0)); then
  classification="empty"
elif [[ -n "$target_pipeline" ]]; then
  if [[ "$target_position" == "not-found" ]]; then
    classification="not-queued"
  elif [[ "$target_position" == "1" ]]; then
    classification="next"
  else
    classification="backlog"
  fi
elif ((repo_queue_depth > 0)); then
  classification="repo-queued"
else
  classification="repo-not-queued"
fi

printf 'queue_depth=%s\n' "$queue_depth"
printf 'repo_queue_depth=%s\n' "$repo_queue_depth"
printf 'target_position=%s\n' "$target_position"
printf 'classification=%s\n' "$classification"
