# Buildkite bootstrap

This directory provides the shared bootstrap for migrating repositories from GitHub Actions to Buildkite without committing Buildkite credentials.

## Security model

- Keep `BUILDKITE_API_TOKEN` only in the process environment or a secret manager. Never commit it.
- The provisioning token needs `read_clusters`, `read_pipelines`, and `write_pipelines`.
- Buildkite API authentication and GitHub repository authentication are separate. A Buildkite API token can create pipelines, but Buildkite still needs its GitHub App authorized for each private repository so agents can clone it and Buildkite can create webhooks.
- Prefer Buildkite's GitHub App and HTTPS repository URLs for private repositories. Do not embed a GitHub PAT or SSH private key in pipeline YAML.
- Rotate provisioning tokens after bootstrap or replace them with a narrowly scoped token used only for pipeline administration.

## Repository contract

Each migrated repository should contain:

```text
.buildkite/
  pipeline.yml
```

The Buildkite pipeline stored in Buildkite itself contains only the bootstrap step:

```yaml
steps:
  - label: ":pipeline: Upload repository pipeline"
    command: "buildkite-agent pipeline upload"
```

This keeps the real pipeline versioned with the source repository and lets pull requests review CI changes.

## Provision pipelines

Requirements: Bash, `curl`, and `jq`.

```bash
export BUILDKITE_API_TOKEN='<token from secret manager>'
export BUILDKITE_ORG_SLUG='<organization-slug>'

bash buildkite/provision.sh owner/repo-a owner/repo-b
```

The script:

1. validates that the token has the minimum required scopes;
2. resolves the Buildkite cluster, preferring `Default cluster` when unambiguous;
3. skips repositories that already have a pipeline in the organization;
4. creates a YAML pipeline whose bootstrap step uploads `.buildkite/pipeline.yml`;
5. asks Buildkite to create the GitHub webhook.

If there are multiple clusters, select one explicitly:

```bash
export BUILDKITE_CLUSTER_NAME='Default cluster'
# or
export BUILDKITE_CLUSTER_ID='<cluster-uuid>'
```

To verify what would be created without writing pipelines:

```bash
BUILDKITE_BOOTSTRAP_DRY_RUN=1 \
  bash buildkite/provision.sh owner/repo-a owner/repo-b
```

## Migration order

Migrate deterministic CI gates first: formatting, linting, type checks, unit tests, builds, and security scanners that do not need production credentials. Keep GitHub Actions release/deploy workflows enabled until the corresponding Buildkite secrets, OIDC trust, approvals, artifact flow, and deployment environment protections have been rebuilt and tested.

For a temporary compatibility phase, Buildkite's GitHub Actions compatibility plugin can run supported workflows without creating a GitHub Actions workflow run. Prefer native Buildkite steps for long-term pipelines, especially for self-hosted runner workloads and production deployment flows.

## Cutover checklist

Before disabling a GitHub Actions workflow, verify all of the following:

- Buildkite GitHub App can clone the private repository.
- Push and pull-request webhooks create Buildkite builds.
- The repository `.buildkite/pipeline.yml` uploads successfully.
- Required checks are updated to the Buildkite commit status/check name.
- Required secrets are present in Buildkite's secret authority or are obtained with OIDC.
- Artifacts and caches have Buildkite equivalents where needed.
- At least one pull request and one default-branch build pass in Buildkite.
- Deployment/release workflows have been separately validated before their GitHub Actions equivalents are disabled.
