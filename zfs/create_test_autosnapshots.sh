#!/bin/bash
set -euo pipefail

# =============================================================================
# Create test autosnapshot-style ZFS snapshots
#
# Intended for use from Unraid User Scripts, where editing variables at the top
# of the script is more convenient than passing command-line arguments.
# =============================================================================

# -----------------------------------------------------------------------------
# USER CONFIGURATION
# -----------------------------------------------------------------------------

# Dataset to snapshot.
# Example:
#   DATASET="cache/appdata/omada-controller-backup"
DATASET=""

# Number of snapshots to create.
SNAPSHOT_COUNT=10

# Snapshot name prefix.
PREFIX="autosnapshot-"

# Seconds between generated snapshot names.
STEP_SECONDS=60

# Optional timestamp anchor in the form:
#   YYYY-MM-DD_HH-MM-SS
# Leave blank to use the current time.
START_TIMESTAMP=""

# backward = generated names end at START_TIMESTAMP / now
# forward  = generated names start at START_TIMESTAMP / now
DIRECTION="backward"

# 1 = print only
# 0 = actually create snapshots
DRY_RUN=0

# -----------------------------------------------------------------------------
# END USER CONFIGURATION
# -----------------------------------------------------------------------------

die() {
  echo "$*" >&2
  exit 1
}

snapshot_exists() {
  local snap="$1"
  zfs list -H -t snapshot -o name "$snap" >/dev/null 2>&1
}

# Unraid User Scripts may invoke scripts with launcher-provided arguments.
# Ignore them and rely only on the variables configured above.

[[ -n "$DATASET" ]] || die "DATASET must be set near the top of the script"
[[ "$SNAPSHOT_COUNT" =~ ^[0-9]+$ ]] || die "SNAPSHOT_COUNT must be a positive integer"
(( SNAPSHOT_COUNT >= 1 )) || die "SNAPSHOT_COUNT must be at least 1"
[[ "$STEP_SECONDS" =~ ^[0-9]+$ ]] || die "STEP_SECONDS must be a non-negative integer"

case "$DIRECTION" in
  backward|forward)
    ;;
  *)
    die "DIRECTION must be 'backward' or 'forward'"
    ;;
esac

command -v zfs >/dev/null 2>&1 || die "zfs command not found"
command -v date >/dev/null 2>&1 || die "date command not found"

zfs list -H -o name "$DATASET" >/dev/null 2>&1 || die "Dataset does not exist: $DATASET"

if [[ -n "$START_TIMESTAMP" ]]; then
  START_EPOCH="$(date -d "${START_TIMESTAMP/_/ }" +%s 2>/dev/null || true)"
  [[ -n "$START_EPOCH" ]] || die "Could not parse START_TIMESTAMP: $START_TIMESTAMP"
else
  START_EPOCH="$(date +%s)"
fi

declare -a SNAPSHOTS=()

if [[ "$DIRECTION" == "backward" ]]; then
  BASE_EPOCH=$((START_EPOCH - ((SNAPSHOT_COUNT - 1) * STEP_SECONDS)))
else
  BASE_EPOCH=$START_EPOCH
fi

for ((i = 0; i < SNAPSHOT_COUNT; i++)); do
  SNAP_EPOCH=$((BASE_EPOCH + (i * STEP_SECONDS)))
  SNAP_TS="$(date -d "@$SNAP_EPOCH" +%Y-%m-%d_%H-%M-%S)"
  SNAPSHOTS+=("${DATASET}@${PREFIX}${SNAP_TS}")
done

for snap in "${SNAPSHOTS[@]}"; do
  if snapshot_exists "$snap"; then
    die "Snapshot already exists: $snap"
  fi
done

echo "Creating ${#SNAPSHOTS[@]} snapshots on dataset: $DATASET"

for ((i = 0; i < ${#SNAPSHOTS[@]}; i++)); do
  snap="${SNAPSHOTS[$i]}"
  current=$((i + 1))

  if (( DRY_RUN == 1 )); then
    echo "[DRY_RUN] [$current/${#SNAPSHOTS[@]}] zfs snapshot '$snap'"
  else
    echo "[$current/${#SNAPSHOTS[@]}] Creating snapshot: $snap"
    zfs snapshot "$snap"
  fi
done

if (( DRY_RUN == 1 )); then
  echo "Done. Planned ${#SNAPSHOTS[@]} snapshots."
else
  echo "Done. Created ${#SNAPSHOTS[@]} snapshots."
fi
