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
Only deploy during an observed idle window. On the CI host:

```sh
sudo ss -Htn state established '( sport = :3188 )'
sudo cp -a /opt/woodpecker/egress-proxy/github_connect.py \
  /opt/woodpecker/egress-proxy/github_connect.py.pre-update
sudo install -o root -g root -m 0644 woodpecker/egress/github_connect.py \
  /opt/woodpecker/egress-proxy/github_connect.py
sudo python3 -m py_compile /opt/woodpecker/egress-proxy/github_connect.py
sudo systemctl restart woodpecker-github-egress.service
sudo systemctl is-active woodpecker-github-egress.service
sudo ss -lnt | grep ':3188 '
```

If the service fails, restore the saved file and restart it. Follow the change
with a restricted CONNECT probe **from a rootless Podman container** and a live
Woodpecker checkout. A successful unauthenticated connection to a private GitHub
repository reaches an authentication error; it does not need to fetch source.

October 23, 2026 live verification: the exact /32 patch passed the restricted
proxy CONNECT probe and Websyt PR #299's dedicated `backup-recovery` workflow
completed with a successful checkout, Restic integrity check, and encrypted
restore smoke test. The corresponding production source was backed up at
`/opt/woodpecker/egress-proxy/github_connect.py.bak-before-rootless-20261023`.
