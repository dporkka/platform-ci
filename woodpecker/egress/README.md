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
two exact Go HTTPS destinations are added; checks for active CONNECT sessions
over a ten-second quiet window; requires an explicit `--confirm-ci-quiesced`
operator acknowledgement when applying, an existing root-owned regular
mode-0644 live file, and refuses to overwrite an existing backup. The quiet
window only samples established connections: it is **not** a substitute for
stopping new CI job admission and coordinating a maintenance window. The helper
rechecks that the live source has not been edited or replaced during the
ten-second quiet window; stages an atomic source-file replacement; restarts
**only** `woodpecker-github-egress.service`; and verifies positive CONNECT
responses for `proxy.golang.org`/`sum.golang.org` and negative responses for
unknown hosts and non-443 requests. It retains
`github_connect.py.before-go-update` beside the live file. If restart or
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
