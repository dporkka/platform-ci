#!/usr/bin/env bash
set -euo pipefail

# Provision Buildkite pipelines for GitHub repositories without storing the
# Buildkite API token in Git, shell history, or pipeline configuration.
#
# Usage:
#   export BUILDKITE_API_TOKEN='...'
#   export BUILDKITE_ORG_SLUG='my-org'
#   bash buildkite/provision.sh owner/repo [owner/repo ...]
#
# Optional:
#   BUILDKITE_CLUSTER_ID=<uuid>
#   BUILDKITE_CLUSTER_NAME='Default cluster'
#   BUILDKITE_DEFAULT_BRANCH=main
#   BUILDKITE_BOOTSTRAP_DRY_RUN=1

API_ROOT="https://api.buildkite.com/v2"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command '$1' was not found" >&2
    exit 1
  }
}

require_command curl
require_command jq

: "${BUILDKITE_API_TOKEN:?Set BUILDKITE_API_TOKEN in the environment}"
: "${BUILDKITE_ORG_SLUG:?Set BUILDKITE_ORG_SLUG to the Buildkite organization slug}"

if [[ "$#" -eq 0 ]]; then
  echo "usage: bash $0 owner/repo [owner/repo ...]" >&2
  exit 2
fi

api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local -a args

  args=(
    --fail-with-body
    --silent
    --show-error
    --request "$method"
    --header "Authorization: Bearer ${BUILDKITE_API_TOKEN}"
    --header "Accept: application/json"
  )

  if [[ -n "$body" ]]; then
    args+=(--header "Content-Type: application/json" --data "$body")
  fi

  curl "${args[@]}" "${API_ROOT}${path}"
}

check_token_scopes() {
  local token_json
  token_json="$(api GET "/access-token")"

  local required=(read_clusters read_pipelines write_pipelines)
  local missing=()
  local scope
  for scope in "${required[@]}"; do
    if ! jq -e --arg scope "$scope" '.scopes | index($scope) != null' <<<"$token_json" >/dev/null; then
      missing+=("$scope")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "error: Buildkite token is missing required scopes: ${missing[*]}" >&2
    echo "       Add the scopes or issue a least-privilege replacement token." >&2
    exit 1
  fi
}

resolve_cluster_id() {
  local clusters
  clusters="$(api GET "/organizations/${BUILDKITE_ORG_SLUG}/clusters?per_page=100")"

  if [[ -n "${BUILDKITE_CLUSTER_ID:-}" ]]; then
    if jq -e --arg id "$BUILDKITE_CLUSTER_ID" '.[] | select(.id == $id)' <<<"$clusters" >/dev/null; then
      printf '%s\n' "$BUILDKITE_CLUSTER_ID"
      return
    fi
    echo "error: BUILDKITE_CLUSTER_ID does not belong to ${BUILDKITE_ORG_SLUG}" >&2
    exit 1
  fi

  if [[ -n "${BUILDKITE_CLUSTER_NAME:-}" ]]; then
    local id
    id="$(jq -r --arg name "$BUILDKITE_CLUSTER_NAME" '[.[] | select(.name == $name)] | if length == 1 then .[0].id else empty end' <<<"$clusters")"
    if [[ -n "$id" ]]; then
      printf '%s\n' "$id"
      return
    fi
    echo "error: expected exactly one cluster named '${BUILDKITE_CLUSTER_NAME}'" >&2
    exit 1
  fi

  local default_id
  default_id="$(jq -r '[.[] | select(.name == "Default cluster")] | if length == 1 then .[0].id else empty end' <<<"$clusters")"
  if [[ -n "$default_id" ]]; then
    printf '%s\n' "$default_id"
    return
  fi

  if [[ "$(jq 'length' <<<"$clusters")" -eq 1 ]]; then
    jq -r '.[0].id' <<<"$clusters"
    return
  fi

  echo "error: multiple Buildkite clusters exist and no unambiguous default was found" >&2
  echo "       Set BUILDKITE_CLUSTER_ID or BUILDKITE_CLUSTER_NAME." >&2
  jq -r '.[] | "       - \(.name): \(.id)"' <<<"$clusters" >&2
  exit 1
}

find_existing_pipeline() {
  local repository="$1"
  local pipelines
  pipelines="$(api GET "/organizations/${BUILDKITE_ORG_SLUG}/pipelines?per_page=100")"

  jq -r --arg repository "$repository" '
    .[]
    | select(
        .provider.settings.repository == $repository
        or .repository == ("https://github.com/" + $repository + ".git")
        or .repository == ("git@github.com:" + $repository + ".git")
      )
    | .slug
  ' <<<"$pipelines" | head -n 1
}

create_pipeline() {
  local repository="$1"
  local cluster_id="$2"
  local default_branch="${BUILDKITE_DEFAULT_BRANCH:-main}"
  local repo_name="${repository##*/}"
  local repo_url="https://github.com/${repository}.git"
  local bootstrap_yaml
  bootstrap_yaml=$'steps:\n  - label: ":pipeline: Upload repository pipeline"\n    command: "buildkite-agent pipeline upload"\n'

  local payload
  payload="$(jq -n \
    --arg name "$repo_name" \
    --arg cluster_id "$cluster_id" \
    --arg repository "$repo_url" \
    --arg configuration "$bootstrap_yaml" \
    --arg default_branch "$default_branch" \
    '{
      name: $name,
      cluster_id: $cluster_id,
      repository: $repository,
      configuration: $configuration,
      default_branch: $default_branch,
      cancel_running_branch_builds: true
    }')"

  if [[ "${BUILDKITE_BOOTSTRAP_DRY_RUN:-0}" == "1" ]]; then
    echo "dry-run: would create Buildkite pipeline for ${repository}"
    return
  fi

  local created slug
  created="$(api POST "/organizations/${BUILDKITE_ORG_SLUG}/pipelines" "$payload")"
  slug="$(jq -r '.slug' <<<"$created")"
  echo "created: ${repository} -> ${BUILDKITE_ORG_SLUG}/${slug}"

  # Buildkite can create the GitHub webhook only after its GitHub App has been
  # connected and granted access to the repository. Keep this failure explicit:
  # a pipeline without a webhook is not a complete replacement for Actions.
  if api POST "/organizations/${BUILDKITE_ORG_SLUG}/pipelines/${slug}/webhook" >/dev/null 2>&1; then
    echo "webhook: configured for ${repository}"
  else
    echo "warning: pipeline created, but Buildkite could not create the GitHub webhook for ${repository}." >&2
    echo "         Connect/authorize the Buildkite GitHub App for this private repository, then rerun the webhook step." >&2
  fi
}

main() {
  check_token_scopes

  local cluster_id
  cluster_id="$(resolve_cluster_id)"
  echo "using Buildkite cluster: ${cluster_id}"

  local repository existing
  for repository in "$@"; do
    if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
      echo "error: invalid GitHub repository '${repository}' (expected owner/repo)" >&2
      exit 2
    fi

    existing="$(find_existing_pipeline "$repository")"
    if [[ -n "$existing" ]]; then
      echo "exists: ${repository} -> ${BUILDKITE_ORG_SLUG}/${existing}"
      continue
    fi

    create_pipeline "$repository" "$cluster_id"
  done
}

main "$@"
