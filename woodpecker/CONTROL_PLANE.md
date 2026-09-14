# Woodpecker control-plane recovery

Use this runbook when GitHub events stop creating Woodpecker pipelines, a pipeline remains pending indefinitely, or commit statuses stop appearing.

The repository workflow should be treated as innocent until the server, forge webhook, scheduler, and agent path are verified. In particular, a Woodpecker `branch: main` condition also applies to pull requests whose target branch is `main`; missing PR pipelines should not be explained away as a source-branch mismatch.

## Fast path

Run the diagnostic on the CI host or another machine that has network access to the Woodpecker server:

```bash
bash woodpecker/scripts/diagnose-control-plane.sh \
  --server https://ci.adacavo.com \
  --repo dporkka/apex
```

The script is read-only by default. It checks:

1. DNS resolution for the public Woodpecker host;
2. the server `/healthz` endpoint (healthy server returns HTTP 204);
3. authenticated `woodpecker-cli info` access when the CLI is available;
4. whether the target repository is present in Woodpecker's repository inventory;
5. whether the target repository has queued pipeline work;
6. local Podman/Docker Woodpecker server/agent container state when run on the host.

Use `--logs` only when needed because container logs can contain operational metadata:

```bash
bash woodpecker/scripts/diagnose-control-plane.sh --logs --log-since 20m
```

## Interpreting failures

### `/healthz` is not 204

The public server/proxy path is unhealthy. Check the reverse proxy, Woodpecker server container/process, database connectivity, and the server logs before touching repository configuration.

### Server is healthy but the repository is missing

Synchronize repository inventory and verify the repository is active in Woodpecker. Do not recreate secrets until repository identity is confirmed.

### Repository exists and work is queued indefinitely

Inspect agent connectivity and capacity. Woodpecker agents connect to the server over gRPC; a healthy UI/API does not prove an agent is connected. Verify the agent container/process is running and that its labels/backend can accept the queued workflow.

### Server is healthy, repository exists, queue is empty, but GitHub events create no pipelines

The forge webhook is the leading suspect. Woodpecker 3.18 exposes a repository webhook repair command. After confirming the target repository, run the diagnostic's explicit repair mode:

```bash
bash woodpecker/scripts/diagnose-control-plane.sh \
  --server https://ci.adacavo.com \
  --repo dporkka/apex \
  --repair-webhook
```

This is intentionally opt-in because it mutates forge integration state.

After repair, generate one normal repository event (for example a PR synchronization) and verify that the exact head SHA receives a fresh `ci/woodpecker/...` commit status.

## Recovery acceptance gate

Do not call the incident resolved merely because the UI loads or a webhook repair command succeeds. Require all of the following:

- `/healthz` returns 204;
- the repository is active in Woodpecker;
- at least one agent is connected/eligible;
- a fresh push or pull-request event creates a new pipeline;
- the pipeline transitions from pending to running;
- real workflow steps execute and logs are available;
- Woodpecker posts the result to the exact GitHub commit SHA;
- a complete representative repository pipeline reaches a terminal state based on executed checks.

For Apex specifically, the representative recovery run should execute Go, Protobuf, Desktop, Native Storage, and Deployment before storage/migration PRs are promoted.

## GitHub Actions is a separate control plane

A Woodpecker recovery does not prove GitHub Actions is healthy, and vice versa. Keep incidents separate when GitHub Actions fails before jobs/steps are created. This avoids debugging repository test code for an account/runner startup failure and avoids changing Woodpecker configuration to compensate for an unrelated Actions outage.
