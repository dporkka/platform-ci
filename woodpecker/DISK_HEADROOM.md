# Read-only disk-headroom preflight

Use `woodpecker/scripts/check-disk-headroom.sh` **on the actual CI host** (not
on a laptop or unrelated container overlay) before scheduling large Go/PostGIS
or restore validation after disk-capacity alarms:

```sh
bash woodpecker/scripts/check-disk-headroom.sh \
  --min-free-gib 20 --max-used-percent 95
bash woodpecker/scripts/check-disk-headroom.test.sh
```

The first command checks the filesystem containing `/`, reports the measured
capacity and threshold in a stable single-line `status=ok` or `status=blocked`
record, and exits 0 or 1 respectively. Bad arguments, malformed `df` output,
or an unavailable disk inspection result are `status=error` (exit 2).
The parser also rejects any `df` output other than one header and exactly
one filesystem row; accepting the last of multiple rows can hide an invalid
or surprising mount selection.
It does **not** delete anything, restart a service, pause job admission, or
certify that the Woodpecker runner sees the same mount. A healthy snapshot can
be invalidated instantly by simultaneous jobs. Recheck after quiescing work.

The conservative defaults are **20 GiB available** and **under 95% usage**.
For parallel PostgreSQL, Rust, and restore jobs, the operator may impose a
larger free-space reserve. These are operational preflight limits rather than
application correctness or restore-proof criteria. If the host is below either
threshold, fix storage capacity/retention before starting large runs; do not
waive PostgreSQL, RLS, checksum or recovery checks.

The original local `ci-disk-guard` timer is separately deployed and continues
to alert about host storage pressure; this portable tool does not install or
replace that timer. In particular, **never run `podman system prune`, delete
active Dagger overlays, remove another user's build files, or clear running
compiler caches** in response to a warning. Controlled cleanup of a user-owned
*rebuildable* Go cache may be considered only when no Go jobs use it; otherwise
quiesce jobs first. Cache cleaning does not solve recurring disk-capacity
pressure and may trigger costly recompilation.

This tool is **not yet an enforced Woodpecker pipeline gate**. To add a gate,
first prove that `df /` inside that precise runner reflects the same capacity
as the target CI host and that the check runs before expensive storage use.
It also does not provide access to authenticated Woodpecker step logs or
authorize the separately reviewed restricted-egress proxy rollout.
