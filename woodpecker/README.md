# Woodpecker CI — shared layer

Woodpecker has no cross-repository `uses:`. The reusable layer is therefore two
things: **scripts** that live here and are downloaded into each pipeline's
workspace, and the **conventions + mapping table** below that every port follows.

Pipelines pin `@v1`, so everything here is served from
`https://raw.githubusercontent.com/dporkka/platform-ci/v1/…`. `main` is the
development line; `v1` is the release line callers depend on. A change to these
scripts is a fleet-wide change — land it on `main`, verify, then advance `v1`.

```
woodpecker/
  scripts/setup-repo.sh    Node/pnpm bootstrap (sourced, POSIX)
  scripts/notify-slack.sh  Slack failure notification (no-op without the secret)
  templates/*.yml          canonical skeletons: node, go, rust, python, mixed
```

## Bootstrap step

First step of **every** pipeline in **every** repository. `curlimages/curl` is used
because it is the one small image guaranteed to have curl; the workspace volume
carries the downloaded files to the later steps.

```yaml
  - name: Bootstrap
    image: curlimages/curl:8.11.1
    commands:
      - mkdir -p .woodpecker/scripts
      - curl -fsSL "https://raw.githubusercontent.com/dporkka/platform-ci/v1/woodpecker/scripts/setup-repo.sh" -o .woodpecker/scripts/setup-repo.sh
      - curl -fsSL "https://raw.githubusercontent.com/dporkka/platform-ci/v1/woodpecker/scripts/notify-slack.sh" -o .woodpecker/scripts/notify-slack.sh
      - chmod +x .woodpecker/scripts/setup-repo.sh .woodpecker/scripts/notify-slack.sh
```

Every later step that needs the toolchain starts with the prelude, **sourced**
(leading dot) so its exports reach the rest of that step. The project it installs
is the current directory:

```yaml
    commands:
      - . .woodpecker/scripts/setup-repo.sh                        # repo root
      - cd apps/web && . "$${CI_WORKSPACE}/.woodpecker/scripts/setup-repo.sh"
```

Use the `$${CI_WORKSPACE}` form when changing directory: `$${VAR}` is how the
*shell* gets a variable (a single `$` is consumed by Woodpecker's config
preprocessor), and it keeps the path correct at any nesting depth — `../`-relative
paths must count the depth (`../../` from `apps/web`).

Do not pass a path as an argument — dash (Woodpecker's step shell in
Debian-based images) does not pass operands to a sourced script, so `$1` arrives
empty and the install would silently run in the workspace root. `SETUP_PROJECT`
(relative to the workspace) is the explicit alternative to `cd`.

`setup-repo.sh` activates pnpm via corepack (`PNPM_VERSION`, default `10.22.0`),
then runs `pnpm install` once per lockfile hash. The stamp lives in
`<project>/node_modules`, inside the workspace volume, so only the first step of a
pipeline pays for the install. Repositories without a committed lockfile are
installed with `--no-frozen-lockfile` and stamped on `package.json`.

## GitHub Actions → Woodpecker v3 mapping

| GitHub Actions | Woodpecker v3 |
| --- | --- |
| `actions/checkout@v4` | implicit clone step |
| `actions/setup-node` + `pnpm/action-setup` | `image: node:22-bookworm` + `. .woodpecker/scripts/setup-repo.sh` |
| `actions/setup-go@v5` | `image: golang:<go.mod version>-bookworm` |
| `dtolnay/rust-toolchain@stable` | `image: rust:<rust-toolchain.toml version>-bookworm` |
| `job.run` (single line) | step `commands:` list |
| `if:` / `on:` | `when:` list form (`when: [{event: [push, pull_request], branch: main}]`) |
| path filters in `on.pull_request.paths` | `when: { event: [pull_request], path: [...] }` |
| `secrets.X` | `from_secret: x` (lowercase snake_case; the env **key** keeps the name the app expects) |
| `needs:` | `depends_on:` (any use makes the workflow a DAG ⇒ all step names must be unique; a job with no `needs` starts with `depends_on: []`) |
| `strategy.matrix` | `matrix:` |
| `services:` | `services:` with the **same image digest** |
| job artifacts (`upload-artifact`/`download-artifact`) | later steps in the same pipeline + a named volume |
| `timeout-minutes` | dropped (step- and workflow-level `timeout` are schema-invalid) |
| `permissions:` / auto `GITHUB_TOKEN` | dropped; a PAT `from_secret` only where the job actually pushed |
| `concurrency.cancel-in-progress` | `concurrency: { limit: 1, group: "<name>" }` |
| `runs-on: [self-hosted, ...]` | dropped — the single agent picks everything up; `labels:` only for the GPU lane |
| `schedule:` | a cron registered out of band (`woodpecker-cli cron add`) |

Retained on GitHub Actions rather than ported, because their steps are
GitHub-platform-only: `labeler`, `stale`, `welcome`, `dependency-review` (GitHub
Apps) and `codeql` (needs the GHAS code-scanning upload endpoint). Everything else
is ported or retired.

## Hard constraints

Verified against `woodpecker-cli 3.18.1`; they override anything in older
Woodpecker/Drone docs.

- Step shell is `/bin/sh -e` (**dash** in Debian-based images): no `[[ ]]`, no
  arrays, no `local`, no `pipefail`. POSIX-ify, or add
  `entrypoint: ["/bin/bash", "-c", "echo $CI_SCRIPT | base64 -d | /bin/bash -e"]`
  on an image that ships bash (not `curlimages/curl`, not the scratch Woodpecker
  images).
- `${VAR}` is expanded at **config-evaluation** time; write `$${VAR}` when the
  *shell* must expand it. `${#arr[@]}`, `${arr[*]}`, `${6:-}` are hard config
  errors that `lint` does not catch.
- YAML anchors live under a top-level `variables:` key (`x-*` and top-level
  `environment:` are schema-invalid). Step and service `environment:` is literal —
  never expanded.
- Every step is a fresh container: only the workspace volume and named volumes
  persist, and an `export` reaches only the rest of that step.
- A repo must be marked **Trusted** for step `volumes:` — otherwise:
  `Insufficient trust level to use volumes`.
- Create secrets with explicit `--event push --event tag --event manual --event
  cron`; **never** scope anything prod-affecting to `pull_request`.

## Verification

```bash
# schema only — not sufficient
woodpecker-cli lint .woodpecker/<file>.yml         # must print "✅ Config is valid"

# real parse + execution against the local container runtime
woodpecker-cli exec --local --repo-path . --repo-trusted-volumes=true \
  --backend-engine docker --secrets-file /tmp/secrets.yml .woodpecker/<file>.yml
```

`exec` needs a container runtime and is unreliable for volume-heavy pipelines; the
real run on the agent is the authority for those.

On an SELinux-enforcing host, `exec` mounts the checkout into the step container
itself, so steps fail with `Permission denied` when reading the repository.
Relabel the checkout first (agent runs are unaffected — their workspace is a
Podman-managed named volume, not a host bind mount):

```bash
chcon -R -t container_file_t <checkout>
```
