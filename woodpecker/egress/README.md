# Private Woodpecker egress bridge

This directory versions the CONNECT-only HTTPS egress proxy used by the
Contabo Woodpecker CI host. It was recovered from the live, validated deployment
on October 23, 2026 (UTC), after Websyt's rootless-Podman agent failed to clone
a private GitHub repository.

## Design and restrictions

- Listen on **Docker-private** `172.17.0.1:3188` and `172.18.0.1:3188` only.
- Accept existing Docker bridge client ranges plus the host's **exact /32**
  address, `82.197.67.39/32`. Rootless Podman source addresses are NATed to
  that host address when crossing to Docker-private bridge listeners.
- Permit HTTP CONNECT to port **443 only**, for explicit domains in `ALLOWED`.
  The Go validation matrix requires the exact `proxy.golang.org` module endpoint
  and `sum.golang.org` checksum endpoint. Do not introduce wildcard hosts or
  disable Go checksum verification.
- Do not log request bodies, intercept TLS, expose the proxy publicly, or turn
  the bridge into a generic outbound HTTP proxy.
- Run under the existing unprivileged `woodpecker-github-egress.service` unit;
  this repository does not include credentials or token materials.

A host-IP change must **fail closed** until the operator updates and tests the
exact /32, and verifies that the server is still bound only to private bridges.
Do not replace the /32 with a broad public CIDR, `0.0.0.0/0`, or a proxy that
intercepts HTTPS.

## Verification

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s woodpecker/egress -p 'test_*.py' -v
python3 -m py_compile woodpecker/egress/github_connect.py
```

The tests include positive and negative client-address checks, deny arbitrary
hosts, non-443 requests and non-CONNECT methods, and exercise permitted host
behavior without making external network requests.

## Controlled deployment

Deploy only after verifying that no jobs have live connections to the egress
bridge. First run the read-only source policy preflight using the **current live
file** and the proposed file (either on the CI host or with a securely retrieved
copy of the live source). It must report that only the two exact Go destinations
are added and no proxy behavior changes:

```sh
python3 woodpecker/egress/check_deployment.py \
  --deployed /opt/woodpecker/egress-proxy/github_connect.py \
  --candidate woodpecker/egress/github_connect.py
```

If the preflight fails, investigate drift before changing the live service.
Only deploy during an operator-approved idle maintenance window, with
Woodpecker jobs quiesced so no new CONNECT sessions can start. On the CI host,
from a trusted checkout of the reviewed source:

```sh
# Read-only preflight; runs without root and makes no service changes.
python3 woodpecker/egress/deploy_go_egress.py \
  --candidate woodpecker/egress/github_connect.py

# Authorized operator only; do not run while CI workflows are active.
sudo python3 woodpecker/egress/deploy_go_egress.py \
  --candidate woodpecker/egress/github_connect.py \
  --apply --confirm-ci-quiesced
```

The one-off helper pins the reviewed candidate Git blob; checks that only the
two exact Go HTTPS destinations are added; **fails closed when the live
filesystem has less than 20 GiB available or reaches 95% utilization**, before
reporting read-only readiness and again immediately before writing a backup.
Malformed filesystem capacity evidence also blocks the rollout. This check is
read-only and does not reserve space: operator-controlled admission quiescence
and adequate sustained disk headroom remain mandatory. A failed capacity check
must never be overridden by clearing active compiler caches or pruning
running Docker/Dagger resources.

The helper additionally refuses to report read-only readiness while **local
`woodpecker-agent` processes** remain present; for an authorized deployment,
operators must stop local agent admission, verify no active builds remain, and
ensure no other agents can begin jobs on this host. It repeats the agent-process
check immediately before publishing the backup. Agent detection uses read-only
`ps` and fails closed if process inspection fails. An empty local process list
does **not** prove cluster-wide scheduling is paused; operator confirmation is
still required. Stop admission using the operator's existing Woodpecker
controls, not by modifying this helper or its safeguards.

The helper also checks for active CONNECT sessions
over a ten-second quiet window; requires an explicit `--confirm-ci-quiesced`
operator acknowledgement when applying, an existing root-owned regular
mode-0644 live file, and refuses to overwrite an existing backup. The quiet
window only samples established connections: it is **not** a substitute for
stopping new CI job admission and coordinating a maintenance window. The helper
rechecks that the live source has not been edited or replaced during the
ten-second quiet window; stages an atomic source-file replacement; restarts
**only** `woodpecker-github-egress.service`; and verifies positive CONNECT
responses for `proxy.golang.org`/`sum.golang.org` and negative responses for
unknown hosts and non-443 requests **on both Docker-private listeners**
(`172.17.0.1:3188` and `172.18.0.1:3188`). A failure on either listener
triggers rollback. It retains
`github_connect.py.before-go-update` beside the live file. The helper now
writes the rollback backup into a private same-filesystem staging file, fsyncs
the complete contents, then atomically publishes the backup via an exclusive
hard link (never replacing an existing file or symlink). It fsyncs the parent
directory before changing the live policy. A failed staging write or file
sync removes the staging file and leaves no partial named backup. A directory
sync failure aborts without changing the live proxy; a complete named backup
may remain and requires operator inspection before retrying. If restart or
probes fail, it restores the original policy and restarts the same service.
If automatic rollback also fails, treat this as a critical incident and use
the saved backup under an authorized recovery procedure. This script neither
grants privileges nor pauses CI pipelines for the operator.

After success, independently verify a restricted CONNECT probe **from a
rootless Podman workflow container** and a real Woodpecker Go-module download
and checksum test. Then run the full Go 1.26/1.27 PostgreSQL/PostGIS matrix and
hosted restore drill. Never infer green hosted checks from proxy health alone.

October 23, 2026 live verification: the exact /32 patch passed the restricted
proxy CONNECT probe and Websyt PR #299's dedicated `backup-recovery` workflow
completed with a successful checkout, Restic integrity check, and encrypted
restore smoke test. The corresponding production source was backed up at
`/opt/woodpecker/egress-proxy/github_connect.py.bak-before-rootless-20261023`.


## Post-deployment Go runner canary (read-only)

After the authorized, quiesced rollout, run the committed
`verify_runner_go_egress.py` **inside each actual Woodpecker Go validation
container** (Go 1.26 and Go 1.27), using a trusted checkout of platform-ci.
A host-only probe is insufficient evidence of runner access:

```sh
# Inside each Go image, after the approved proxy rollout:
python3 woodpecker/egress/verify_runner_go_egress.py
```

The script accepts only `HTTPS_PROXY=http://172.17.0.1:3188` or
`http://172.18.0.1:3188`; it checks CONNECT **200** for the two exact Go
module and checksum origins plus GitHub, and CONNECT **403** for an unknown
origin and non-443 traffic. It then creates a fresh temporary Go module/cache
directory and executes an actual `go mod download github.com/google/uuid@v1.6.0`
with end-to-end TLS and `GOSUMDB=sum.golang.org` enforced.

For that child process only, `NO_PROXY` and public-module exceptions are
cleared to *require use of the restricted proxy*, not direct internet egress.
No credentials, root privileges, source changes or service restarts are needed.

**Do not use `go mod download -json` as the sole canary:** Go can exit zero while
reporting a dependency download error in its JSON. The verified non-JSON
command must exit zero. No TLS or checksum verification is disabled.

The canary is an additional operator proof, **not a replacement** for exact-head
Woodpecker Go 1.26/1.27 CI, PostgreSQL/PostGIS tenant RLS or the independent
logical-restore drill. A failed canary must block promotion rather than
encourage clearing the HTTP proxy or bypassing the restricted network policy.

Run its dependency-free regression tests with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s woodpecker/egress -p 'test_*.py'
```
