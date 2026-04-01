#!/bin/bash
set -euo pipefail

# =============================================================================
# ZFS Automatic Snapshot Script for Unraid
#
# Runs well under Unraid "User Scripts" (typically executed as root).
#
# What it does (in this order):
#  1) Time-based retention cleanup (ONLY snapshots with PREFIX)
#  2) Space-based cleanup if pool free space falls below configured thresholds
#  3) Creates a fresh snapshot for each configured dataset
#
# SAFETY:
#  - This script ONLY destroys snapshots whose name contains "@${PREFIX}".
#  - Any snapshots not matching that prefix are never touched.
# =============================================================================

# -----------------------------------------------------------------------------
# USER CONFIGURATION
# -----------------------------------------------------------------------------

# DATASETS
#   Comma-separated list of: dataset:threshold
#
#   dataset:
#     Full ZFS dataset path (recursive snapshots apply under this dataset).
#     Example: tank/media or storage/Multimedia
#
#   threshold:
#     Minimum free space you want to maintain on the POOL that dataset belongs to.
#     If multiple listed datasets are on the same pool, the script uses the
#     LARGEST threshold for that pool.
#
#   Units supported (case-insensitive), optional trailing B:
#     K, M, G, T  (KB, MB, GB, TB also accepted)
#   Examples:
#     500M, 100G, 2T, 750MB, 1TB
#
DATASETS="zfs/ResilioSync:100G,zfs/Multimedia:100G,cache/appdata:200G,external/Backup:500G,zfs/Backup:500G"

# PREFIX
#   Only snapshots containing "@${PREFIX}" will ever be deleted by this script.
PREFIX="autosnapshot-"

# DRY_RUN
#   1 = print actions only (no destroys, no snapshots)
#   0 = actually do it
DRY_RUN=0

# RETENTION POLICY BY SNAPSHOT AGE
#
#  - Keep ALL snapshots newer than or equal to KEEP_ALL_FOR_DAYS
#  - For snapshots older than KEEP_ALL_FOR_DAYS and up to KEEP_DAILY_UNTIL_DAYS:
#       keep 1 per day (newest snapshot per day), delete the rest
#  - For snapshots older than KEEP_DAILY_UNTIL_DAYS and up to KEEP_WEEKLY_UNTIL_DAYS:
#       keep 1 per week (newest snapshot per week), delete the rest
#  - Anything older than KEEP_WEEKLY_UNTIL_DAYS is deleted
#
KEEP_ALL_FOR_DAYS=14
KEEP_DAILY_UNTIL_DAYS=30
KEEP_WEEKLY_UNTIL_DAYS=183

# LOCKING
#   Prevent overlapping runs (important on Unraid if User Scripts is scheduled
#   frequently and a run sometimes takes longer than expected).
#
#   /tmp is safe on Unraid and always writable.
LOCKFILE="/tmp/zfs_autosnapshot.lock"
LOCKDIR="/tmp/zfs_autosnapshot.lockdir"   # used only if flock is unavailable

# -----------------------------------------------------------------------------
# END USER CONFIGURATION
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Unraid-friendly sanity checks
# -----------------------------------------------------------------------------
if ! command -v zfs >/dev/null 2>&1 || ! command -v zpool >/dev/null 2>&1; then
  echo "zfs/zpool commands not found. Is ZFS installed and loaded on this Unraid system?"
  exit 1
fi

# -----------------------------------------------------------------------------
# Acquire exclusive lock (non-blocking)
#   Prefer flock (best). Fallback to mkdir-based lock if flock is not available.
# -----------------------------------------------------------------------------
acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
      echo "Another instance is already running (lock: $LOCKFILE). Exiting."
      exit 0
    fi
    # For debugging: record PID holding the lock
    echo "$$" 1>&200
  else
    # mkdir lock fallback:
    # - mkdir is atomic
    # - we store PID inside and cleanup on exit
    if ! mkdir "$LOCKDIR" 2>/dev/null; then
      echo "Another instance is already running (lock: $LOCKDIR). Exiting."
      exit 0
    fi
    echo "$$" > "$LOCKDIR/pid"
    trap 'rm -rf "$LOCKDIR"' EXIT
  fi
}
acquire_lock

# -----------------------------------------------------------------------------
# Time constants (days -> seconds)
# -----------------------------------------------------------------------------
KEEP_ALL_FOR_SECONDS=$((KEEP_ALL_FOR_DAYS * 86400))
KEEP_DAILY_UNTIL_SECONDS=$((KEEP_DAILY_UNTIL_DAYS * 86400))
KEEP_WEEKLY_UNTIL_SECONDS=$((KEEP_WEEKLY_UNTIL_DAYS * 86400))
NOW_EPOCH="$(date +%s)"

# Retention must step outward correctly or it will behave oddly.
if ! (( KEEP_ALL_FOR_DAYS < KEEP_DAILY_UNTIL_DAYS && KEEP_DAILY_UNTIL_DAYS < KEEP_WEEKLY_UNTIL_DAYS )); then
  echo "Retention config invalid: must be KEEP_ALL_FOR_DAYS < KEEP_DAILY_UNTIL_DAYS < KEEP_WEEKLY_UNTIL_DAYS" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log() { echo "$@"; }

do_destroy() {
  local snap="$1"
  if (( DRY_RUN )); then
    log "[DRY_RUN] zfs destroy '$snap'"
  else
    zfs destroy "$snap"
  fi
}

do_snapshot() {
  local snap="$1"
  if (( DRY_RUN )); then
    log "[DRY_RUN] zfs snapshot '$snap'"
  else
    zfs snapshot "$snap"
  fi
}

# Convert "100G", "500MB", "2T", etc. into bytes (1024-based).
threshold_to_bytes() {
  local raw="$1"
  local upper num unit

  # Normalize: uppercase and strip optional trailing 'B'
  upper="$(echo "$raw" | tr '[:lower:]' '[:upper:]')"
  upper="${upper%B}"

  # numeric part and unit part
  num="${upper%[A-Z]*}"
  unit="${upper:${#num}}"

  if [[ -z "$num" || ! "$num" =~ ^[0-9]+$ ]]; then
    echo "Bad threshold '$raw' (expected like 500M, 100G, 2T)" >&2
    exit 1
  fi

  case "$unit" in
    K) echo $((num * 1024)) ;;
    M) echo $((num * 1024 * 1024)) ;;
    G) echo $((num * 1024 * 1024 * 1024)) ;;
    T) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
    *) echo "Bad unit in '$raw' (use K, M, G, or T, optional B: GB/TB)" >&2; exit 1 ;;
  esac
}

# Pool available bytes from ZFS's perspective (numeric).
get_pool_avail() { zfs list -o avail -H -p "$1"; }

# "freeing" may be missing or "-". Treat as 0 if not numeric.
get_pool_freeing() {
  local v
  v="$(zpool get -H -o value freeing "$1" 2>/dev/null || true)"
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

# -----------------------------------------------------------------------------
# 1) Time-based retention cleanup for one dataset
# -----------------------------------------------------------------------------
time_clean_dataset() {
  local ds="$1"
  log "Time-based cleanup for dataset: $ds"

  # List snapshots under ds (recursive), newest first.
  # Output format: name<TAB>creation_epoch
  local snaps
  snaps="$(zfs list -H -p -t snapshot -o name,creation -S creation -r "$ds" | grep "@${PREFIX}" || true)"

  if [[ -z "$snaps" ]]; then
    log "  No ${PREFIX} snapshots found."
    return 0
  fi

  # We keep track of days/weeks already satisfied.
  # Since we iterate newest -> oldest, the first one we see for a day/week is the one we keep.
  declare -A kept_day=()
  declare -A kept_week=()

  while IFS=$'\t' read -r snap_name snap_created; do
    [[ -z "$snap_name" || -z "$snap_created" ]] && continue
    local age=$((NOW_EPOCH - snap_created))

    # Oldest tier: beyond weekly retention window
    if (( age > KEEP_WEEKLY_UNTIL_SECONDS )); then
      log "  Deleting (older than ${KEEP_WEEKLY_UNTIL_DAYS}d): $snap_name"
      do_destroy "$snap_name"
      continue
    fi

    # Weekly tier: keep newest per week
    if (( age > KEEP_DAILY_UNTIL_SECONDS )); then
      local week_key
      week_key="$(date -d @"$snap_created" +%Y-%W)"
      if [[ -z "${kept_week[$week_key]:-}" ]]; then
        kept_week["$week_key"]=1
        log "  Keeping weekly latest: $snap_name"
      else
        log "  Deleting weekly duplicate: $snap_name"
        do_destroy "$snap_name"
      fi
      continue
    fi

    # Daily tier: keep newest per day
    if (( age > KEEP_ALL_FOR_SECONDS )); then
      local day_key
      day_key="$(date -d @"$snap_created" +%Y-%m-%d)"
      if [[ -z "${kept_day[$day_key]:-}" ]]; then
        kept_day["$day_key"]=1
        log "  Keeping daily latest: $snap_name"
      else
        log "  Deleting daily duplicate: $snap_name"
        do_destroy "$snap_name"
      fi
      continue
    fi

    # Recent tier: keep everything
    log "  Keeping recent: $snap_name"
  done <<< "$snaps"
}

# -----------------------------------------------------------------------------
# Parse DATASETS into array "pairs"
# -----------------------------------------------------------------------------
IFS=',' read -r -a pairs <<< "$DATASETS"

# pool_min_free_bytes[pool] = minimum free space target for that pool (bytes)
# If multiple datasets in the same pool specify thresholds, we keep the maximum.
declare -A pool_min_free_bytes=()

# -----------------------------------------------------------------------------
# Phase A: time-based cleanup + compute per-pool thresholds
# -----------------------------------------------------------------------------
for pair in "${pairs[@]}"; do
  ds="${pair%:*}"
  thresh="${pair##*:}"

  pool="${ds%%/*}"
  thresh_bytes="$(threshold_to_bytes "$thresh")"

  if [[ -z "${pool_min_free_bytes[$pool]:-}" || "$thresh_bytes" -gt "${pool_min_free_bytes[$pool]}" ]]; then
    pool_min_free_bytes["$pool"]="$thresh_bytes"
  fi

  time_clean_dataset "$ds"
done

# -----------------------------------------------------------------------------
# Phase B: space-based cleanup (globally oldest eligible snapshot)
#
# If a pool's effective free space is below its configured threshold, delete
# the oldest eligible snapshot among ONLY the listed datasets on that pool.
#
# "Globally oldest" works well when your datasets snapshot on the same schedule
# and are roughly the same age.
# -----------------------------------------------------------------------------
for pool in "${!pool_min_free_bytes[@]}"; do
  min_free="${pool_min_free_bytes[$pool]}"

  while :; do
    avail="$(get_pool_avail "$pool")"
    freeing="$(get_pool_freeing "$pool")"
    effective_avail=$((avail + freeing))

    if (( effective_avail >= min_free )); then
      log "Pool $pool OK: effective_avail=$effective_avail bytes (>= $min_free)."
      break
    fi

    # Build list: name<TAB>creation_epoch for eligible snapshots on this pool.
    snapshot_list=""
    for pair in "${pairs[@]}"; do
      ds="${pair%:*}"
      this_pool="${ds%%/*}"
      [[ "$this_pool" != "$pool" ]] && continue

      snaps="$(zfs list -H -p -t snapshot -o name,creation -S creation -r "$ds" | grep "@${PREFIX}" || true)"
      [[ -n "$snaps" ]] && snapshot_list+="$snaps"$'\n'
    done

    if [[ -z "$snapshot_list" ]]; then
      log "Pool $pool low on space, but no ${PREFIX} snapshots remain to delete for listed datasets."
      break
    fi

    # Oldest first by creation time (2nd field).
    oldest_line="$(printf "%s" "$snapshot_list" | sort -k2n | head -n 1)"
    oldest_snap="$(printf "%s" "$oldest_line" | awk '{print $1}')"

    log "Pool $pool low on space -> deleting oldest eligible snapshot: $oldest_snap"
    do_destroy "$oldest_snap"
  done
done

# -----------------------------------------------------------------------------
# Phase C: create new snapshots
# -----------------------------------------------------------------------------
timestamp="$(date +%Y-%m-%d_%H-%M-%S)"

for pair in "${pairs[@]}"; do
  ds="${pair%:*}"
  new_snap="$ds@${PREFIX}${timestamp}"
  log "Creating snapshot: $new_snap"
  do_snapshot "$new_snap"
done

log "Snapshot management complete."
