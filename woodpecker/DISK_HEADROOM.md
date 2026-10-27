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


## Operator response when the headroom gate blocks

Do not equate the absence of a visible `cargo` process with a drained
Woodpecker queue. A new job may start immediately after inspection. This
procedure is deliberately separated from the check script and requires an
authorized operator:

1. **Quiesce admission first.** Use the CI control plane and a reviewed
   maintenance window to prevent new jobs, then let active jobs complete.
   Confirm the queue and agents are drained with authenticated evidence;
   never terminate unrelated builds to make the disk check pass.
2. **Capture filesystem and activity evidence without writing:**

   ```sh
   df -B1 --output=size,used,avail,pcent /
   du -sh /tmp/cargo-target/debug/incremental \
          /tmp/cargo-target/debug/deps \
          /home/ci-agent/.cache/go-build 2>/dev/null
   ps -eo pid,etime,comm,args | grep -E '[c]argo|[r]ustc|[g]o test'
   ss -Htn state established '( sport = :3188 )'
   ```

   These are examples for the current CI host layout, **not** permission
   to purge those paths. A zero process count or zero proxy sessions at one
   instant is insufficient to prove admission quiescence.
3. **Select only individually verified, rebuildable artifacts.** Require
   documented path ownership, the originating job/project, proof that the
   job is complete, and an approved retention policy before any removal.
   Never delete an entire shared Cargo target, another project's active
   incremental cache, image/volume, backup, or running overlay merely because
   `du` shows it is large. The read-only tool does not perform cleanup.
4. **Recheck both constraints after capacity is stabilized:** free space
   must be at least **20 GiB**, *and* filesystem utilization must be
   **strictly below 95%**. On a roughly 484 GiB volume, the utilization rule
   implies a larger practical free-space reserve than 20 GiB. Plan additional
   room for concurrent Go/PostGIS/Rust builds rather than operating exactly
   on either threshold.
5. **Then**, and only in the separate authorized maintenance workflow,
   run the reviewed restricted-egress deployment preflight. The proxy
   deployment in platform-ci #21 also requires explicit admission-quiescence
   confirmation and repeated zero-CONNECT checks, then a reversible narrow
   policy rollout. Passing this disk check alone never authorizes a restart.
6. Keep general CI admission paused while the operator permits **only**
   controlled validation canary jobs to run against the reviewed policy.
   Require in-runner Go module/checksum allow/deny proof and executable
   exact-head Vertigo Go/PostGIS/RLS/restore checks. Resume normal admission
   only after validation and rollback readiness are verified; do not change
   GitHub required checks to accommodate failures.

If any condition cannot be independently verified, stop and preserve the
current state. Record disk measurements and blocked checks in platform-ci
#20/#22 and Vertigo #50 rather than claiming release readiness.
