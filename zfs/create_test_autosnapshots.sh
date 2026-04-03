#!/bin/bash
set -euo pipefail

PREFIX="autosnapshot-"
STEP_SECONDS=60
START_TIMESTAMP=""
DIRECTION="backward"
DRY_RUN=0
DATASET=""
COUNT=""

usage() {
  cat <<'EOF'
Usage:
  create_test_autosnapshots.sh --dataset DATASET --count N [options]

Required:
  --dataset DATASET         ZFS dataset to snapshot
  --count N                 Number of snapshots to create

Options:
  --prefix PREFIX           Snapshot name prefix (default: autosnapshot-)
  --start YYYY-MM-DD_HH-MM-SS
                            Timestamp to anchor the generated names
                            (default: current time)
  --step-seconds N          Seconds between generated snapshot names
                            (default: 60)
  --direction backward      Generate names ending at --start / now (default)
  --direction forward       Generate names starting at --start / now
  --dry-run                 Print snapshots that would be created
  -h, --help                Show this help

Notes:
  - Snapshot names are generated like:
      cache/appdata/example@autosnapshot-2026-04-03_12-53-05
  - This only controls the snapshot names. ZFS creation time is still the
    actual moment each snapshot is created.
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

snapshot_exists() {
  local snap="$1"
  zfs list -H -t snapshot -o name "$snap" >/dev/null 2>&1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dataset)
      [[ $# -ge 2 ]] || die "--dataset requires a value"
      DATASET="$2"
      shift 2
      ;;
    --count)
      [[ $# -ge 2 ]] || die "--count requires a value"
      COUNT="$2"
      shift 2
      ;;
    --prefix)
      [[ $# -ge 2 ]] || die "--prefix requires a value"
      PREFIX="$2"
      shift 2
      ;;
    --start)
      [[ $# -ge 2 ]] || die "--start requires a value"
      START_TIMESTAMP="$2"
      shift 2
      ;;
    --step-seconds)
      [[ $# -ge 2 ]] || die "--step-seconds requires a value"
      STEP_SECONDS="$2"
      shift 2
      ;;
    --direction)
      [[ $# -ge 2 ]] || die "--direction requires a value"
      DIRECTION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$DATASET" ]] || die "--dataset is required"
[[ -n "$COUNT" ]] || die "--count is required"
[[ "$COUNT" =~ ^[0-9]+$ ]] || die "--count must be a positive integer"
(( COUNT >= 1 )) || die "--count must be at least 1"
[[ "$STEP_SECONDS" =~ ^[0-9]+$ ]] || die "--step-seconds must be a non-negative integer"

case "$DIRECTION" in
  backward|forward)
    ;;
  *)
    die "--direction must be 'backward' or 'forward'"
    ;;
esac

command -v zfs >/dev/null 2>&1 || die "zfs command not found"
command -v date >/dev/null 2>&1 || die "date command not found"

zfs list -H -o name "$DATASET" >/dev/null 2>&1 || die "Dataset does not exist: $DATASET"

if [[ -n "$START_TIMESTAMP" ]]; then
  START_EPOCH="$(date -d "${START_TIMESTAMP/_/ }" +%s 2>/dev/null || true)"
  [[ -n "$START_EPOCH" ]] || die "Could not parse --start timestamp: $START_TIMESTAMP"
else
  START_EPOCH="$(date +%s)"
fi

declare -a SNAPSHOTS=()

if [[ "$DIRECTION" == "backward" ]]; then
  BASE_EPOCH=$((START_EPOCH - ((COUNT - 1) * STEP_SECONDS)))
else
  BASE_EPOCH=$START_EPOCH
fi

for ((i = 0; i < COUNT; i++)); do
  SNAP_EPOCH=$((BASE_EPOCH + (i * STEP_SECONDS)))
  SNAP_TS="$(date -d "@$SNAP_EPOCH" +%Y-%m-%d_%H-%M-%S)"
  SNAPSHOTS+=("${DATASET}@${PREFIX}${SNAP_TS}")
done

for snap in "${SNAPSHOTS[@]}"; do
  if snapshot_exists "$snap"; then
    die "Snapshot already exists: $snap"
  fi
done

for snap in "${SNAPSHOTS[@]}"; do
  if (( DRY_RUN == 1 )); then
    echo "[DRY_RUN] zfs snapshot '$snap'"
  else
    echo "Creating snapshot: $snap"
    zfs snapshot "$snap"
  fi
done

echo "Done."
