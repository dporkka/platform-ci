# platform-ci

Public reusable GitHub Actions workflows shared across `dporkka/*`, `nulang-org/*`, and other repositories.

## Workflows

- `reusable-detect.yml` — affected-area detection for Rust, Node, Python, Go, Docker, infra, docs, and CI files
- `reusable-rust.yml` — configurable Rust fmt/check/clippy/test gates
- `reusable-node.yml` — Node.js CI for pnpm/npm/yarn/bun
- `reusable-go.yml` — Go vet/test/build gates
- `reusable-python.yml` — Python install/lint/test gates

Callers own triggers, concurrency, permissions, secrets, service containers, and repository-specific policy. Generic deterministic language validation belongs here.

Production callers should reference the stable `v1` branch, or an immutable commit SHA for maximum reproducibility. `main` is the development line; advance `v1` only after `Validate Platform CI` is green.

See `SHARED_CI.md` for examples and migration guidance.
