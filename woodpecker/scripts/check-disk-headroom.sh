#!/usr/bin/env bash
# Read-only capacity acceptance for the filesystem visible to this process.
# No cache deletion, cleanup, service calls or remote API access.
set -euo pipefail

min_free_gib=20
max_used_percent=95
usage() {
  echo 'Usage: check-disk-headroom.sh [--min-free-gib N] [--max-used-percent N]' >&2
}
error() {
  printf 'status=error reason=%s\n' "$1" >&2
  exit 2
}
while (($#)); do
  case "$1" in
    --min-free-gib)
      (($# >= 2)) || error missing_min_free_gib
      min_free_gib="$2"
      shift 2 ;;
    --max-used-percent)
      (($# >= 2)) || error missing_max_used_percent
      max_used_percent="$2"
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) error unexpected_argument ;;
  esac
done
[[ "$min_free_gib" =~ ^[0-9]+$ ]] || error invalid_min_free_gib
[[ "$max_used_percent" =~ ^[0-9]+$ ]] || error invalid_max_used_percent
(( ${#min_free_gib} <= 8 )) || error invalid_min_free_gib
(( ${#max_used_percent} <= 3 )) || error invalid_max_used_percent
min_free_gib=$((10#$min_free_gib))
max_used_percent=$((10#$max_used_percent))
((min_free_gib >= 1 && min_free_gib <= 1024)) || error invalid_min_free_gib
((max_used_percent >= 1 && max_used_percent <= 100)) || error invalid_max_used_percent

# Deliberately fixed to / to prevent a runner inspecting an unrelated mount.
# GNU df is already required by the deployed CI host's read-only monitor.
if ! listing="$(df -B1 --output=size,used,avail,pcent / 2>/dev/null)"; then
  error df_unavailable
fi
mapfile -t df_lines <<< "$listing"
((${#df_lines[@]} == 2)) || error unexpected_df_rows
read -r total used available percent extra <<< "${df_lines[1]}"
[[ "$percent" =~ ^[0-9]+%$ ]] || error malformed_df
percent="${percent%%%}"
for value in "$total" "$used" "$available" "$percent"; do
  [[ "$value" =~ ^[0-9]+$ ]] || error malformed_df
  ((${#value} <= 18)) || error malformed_df
done
[[ -z "${extra:-}" ]] || error malformed_df
(( total > 0 && used <= total && available <= total && used + available <= total )) || error inconsistent_df
(( percent <= 100 )) || error malformed_df

min_free_bytes=$((min_free_gib * 1073741824))
free_gib=$((available / 1073741824))
if ((available < min_free_bytes || percent >= max_used_percent)); then
  printf 'status=blocked filesystem=/ used_percent=%s free_gib=%d min_free_gib=%d max_used_percent=%d\n' \
    "$percent" "$free_gib" "$min_free_gib" "$max_used_percent"
  exit 1
fi
printf 'status=ok filesystem=/ used_percent=%s free_gib=%d min_free_gib=%d max_used_percent=%d\n' \
  "$percent" "$free_gib" "$min_free_gib" "$max_used_percent"
