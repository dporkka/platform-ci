# Woodpecker control-plane recovery

Use this runbook when GitHub events stop creating Woodpecker pipelines, a pipeline remains pending indefinitely, or commit statuses stop appearing.

The repository workflow should be treated as innocent until the server, forge webhook, scheduler, and agent path are verified. In particular, a Woodpecker `branch: main` condition also applies to pull requests whose target branch is `main`; missing PR pipelines should not be explained away as a source-branch mismatch.

## Fast path

Run the diagnostic on the CI host or another machine that has network access to the Woodpecker server:

```bash
bash woodpecker/scripts/diagnose-control-plane.sh \
  --server https://ci.adacavo.com \
  --repo dporkka/ochem-app
```

The diagnostic is read-only by default. It checks DNS, `/healthz`, Cloudflare Error 1033, `cloudflared.service`, authenticated Woodpecker CLI access, repository inventory, queue state, and local Woodpecker containers in both Docker and Podman when those runtimes are installed.

Use `--logs` only when needed because container logs can contain operational metadata:

```bash
bash woodpecker/scripts/diagnose-control-plane.sh \
  --server https://ci.adacavo.com \
  --repo dporkka/ochem-app \
  --logs --log-since 30m
```

## Guarded recovery helper

When diagnostics show a host/tunnel/container problem, use the recovery helper. It is **dry-run by default**:

```bash
bash woodpecker/scripts/recover-control-plane.sh \
  --server https://ci.adacavo.com
```

Review the proposed actions first. The default applied mode only restarts `cloudflared.service` when it is inactive. It inspects both Docker and Podman, reports stopped Woodpecker containers, and leaves all containers untouched unless an explicit container action is requested:

```bash
bash woodpecker/scripts/recover-control-plane.sh \
  --server https://ci.adacavo.com \
  --apply
```

A stopped Woodpecker container is **not** started automatically. After confirming that it is the intended active instance, start it explicitly with a runtime-qualified name:

```bash
bash woodpecker/scripts/recover-control-plane.sh \
  --server https://ci.adacavo.com \
  --apply --start-container docker:woodpecker-agent
```

`--start-container` is repeatable and also accepts `podman:<name>`. This avoids accidentally resurrecting retired or duplicate Woodpecker instances merely because their name or image contains `woodpecker`.

If a pipeline is confirmed queued/pending but an otherwise-running agent is not claiming work, explicitly restart the running agent container(s) discovered across the installed runtimes:

```bash
bash woodpecker/scripts/recover-control-plane.sh \
  --server https://ci.adacavo.com \
  --apply --restart-agent
```

Use `--restart-server` only with stronger evidence that the Woodpecker server process itself is unhealthy. A server restart can affect active pipelines, so it is intentionally opt-in.

The recovery helper never changes repository configuration, Woodpecker repository settings, tunnel configuration, or secrets.

## Interpreting failures

### `/healthz` returns Cloudflare Error 1033

Error 1033 means Cloudflare has the hostname/tunnel mapping but cannot reach a healthy tunnel connector. Treat this as tunnel/host infrastructure failure, not as a repository test failure.

For the `ci.adacavo.com` deployment, the tunnel is expected to be provided by the workstation user service `cloudflared.service`; its token environment file is `~/.config/cloudflared/ci-adacavo.env`. Do not print or copy the token while diagnosing the incident.

On the CI workstation:

```bash
systemctl --user status cloudflared.service --no-pager
journalctl --user -u cloudflared.service --since "30m" --no-pager | tail -n 200
```

If the service is inactive, failed, or disconnected, restart it:

```bash
systemctl --user restart cloudflared.service
systemctl --user status cloudflared.service --no-pager
```

Also verify user lingering remains enabled so the tunnel is not tied to an interactive login session:

```bash
loginctl show-user "$USER" -p Linger
```

After recovery, require:

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' https://ci.adacavo.com/healthz
```

to return `204`, then rerun the diagnostic and trigger a fresh repository event so Woodpecker posts a status for the exact new commit SHA.

### `/healthz` is not 204 for another reason

The public server/proxy path is unhealthy. Check the reverse proxy, Woodpecker server container/process, database connectivity, and server logs before touching repository configuration.

### Repository exists and work is queued indefinitely

Inspect agent connectivity and capacity. Woodpecker agents connect to the server over gRPC; a healthy UI/API does not prove an agent is connected. Verify the agent container/process is running and that its labels/backend can accept the queued workflow.

For this condition, prefer:

```bash
bash woodpecker/scripts/recover-control-plane.sh --apply --restart-agent
```

rather than changing application workflow YAML.

### Server is healthy, repository exists, queue is empty, but GitHub events create no pipelines

The forge webhook is the leading suspect. After confirming the target repository, run the diagnostic's explicit repair mode:

```bash
bash woodpecker/scripts/diagnose-control-plane.sh \
  --server https://ci.adacavo.com \
  --repo dporkka/ochem-app \
  --repair-webhook
```

This is intentionally opt-in because it mutates forge integration state.

## Recovery acceptance gate

Do not call the incident resolved merely because the UI loads, the tunnel service restarts, or a webhook repair command succeeds. Require all of the following:

- `/healthz` returns 204;
- the repository is active in Woodpecker;
- at least one agent is connected/eligible;
- a fresh push or pull-request event creates a new pipeline;
- the pipeline transitions from pending to running;
- real workflow steps execute and logs are available;
- Woodpecker posts the result to the exact GitHub commit SHA;
- a complete representative repository pipeline reaches a terminal state based on executed checks.

For `ochem-app`, the representative recovery run must at minimum execute `runner-smoke`, `quality`, and `backend-tests` on the exact candidate SHA before billing/auth or release-hardening PRs are promoted.

## GitHub Actions is a separate control plane

A Woodpecker recovery does not prove GitHub Actions is healthy, and vice versa. Keep incidents separate when GitHub Actions fails before jobs/steps are created. This avoids debugging repository test code for an account/runner startup failure and avoids changing Woodpecker configuration to compensate for an unrelated Actions outage.
