# Platform CI scripts

## `runner-pool.sh`

Manages a bounded pool of official GitHub Actions self-hosted runners for one repository on one Linux host.

The helper deliberately does **not** fetch runner binaries or registration tokens. Obtain the official Linux x64 runner archive, SHA-256, and short-lived registration/removal token from the target repository's **Settings → Actions → Runners** page, then pass them through environment variables.

This keeps the trust boundary explicit:

- official GitHub runner archive only;
- checksum verified before extraction;
- registration/removal token kept out of the repository;
- one install directory and `_work` tree per runner process;
- standard `self-hosted`, `Linux`, and `X64` labels preserved;
- concurrency bounded by `RUNNER_COUNT` (default `2`).

See [`../SELF_HOSTED_RUNNERS.md`](../SELF_HOSTED_RUNNERS.md) for the Apex two-worker procedure and capacity guidance.
