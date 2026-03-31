#!/bin/bash

# migrate_appdirs_to_datasets.sh
#
# Converts plain directories directly under:
#   /mnt/cache/appdata   (dataset: cache/appdata)
#   /mnt/cache/starrapps (dataset: cache/starrapps)
# into individual child ZFS datasets.
#
# Safety model:
# - Stops running Docker containers gracefully, but does not stop or kill the Docker daemon itself.
#   It waits until containers have exited rather than forcing them to stop or killing dockerd.
# - Checks mover is not running; dies if it is.
# - Checks parity is not running; dies if it is.
# - Skips anything already its own dataset.
# - Skips and warns on leftover .__migration_tmp__. directories so a
#   crashed prior run is never silently re-migrated under a mangled name.
# - Renames original dir to a temp name.
# - Creates child dataset with original name.
# - Copies with rsync.
# - Verifies with:
#   1) rsync checksum dry-run (with full diff logged on failure)
#   2) SHA-256 manifest compare of regular files
#   3) symlink manifest compare
#   4) directory/file/symlink count compare
# - Deletes temp source only after all verification passes.
# - Waits for adequate free space instead of failing immediately.
# - Reboots cleanly via shutdown -r (goes through Unraid array teardown)
#   only if at least one migration happened.
#
# KNOWN UNRAID CAVEAT:
# Manually created child datasets are not tracked by emhttpd. The clean
# reboot at the end is essential. After rebooting, verify the Unraid WebUI
# shows all datasets correctly before re-enabling Docker autostart.
# If you ever see "dataset is busy" on array stop, run:
#   zfs unmount -a && zpool export cache
# then use the Unraid UI to stop/start the array.
#
# IMPORTANT:
# - Run as root during a maintenance window.
# - Disable the Mover schedule before running.
# - Disable CA Backup and any other scheduled tasks before running.
# - Stop any parity check before running.
# - Read the script before running it.
# - Test on one sacrificial folder first.
# - The log is written to /boot/logs/ (persistent flash) so it survives
#   the reboot this script may trigger.

set -Eeuo pipefail
IFS=$'\n\t'

########################################
# CONFIG
########################################

POOL_NAME="cache"

PARENT_DATASETS=(
  "cache/appdata"
  "cache/starrapps"
)

REBOOT_WAIT_SECONDS=120
SPACE_RECHECK_SECONDS=300          # 5 minutes
ABSOLUTE_SAFETY_MARGIN=$((1024 * 1024 * 1024))   # 1 GiB minimum cushion
PERCENT_SAFETY_MARGIN=10           # plus 10% of source size
LOCK_FILE="/var/lock/migrate_appdirs_to_datasets.lock"

# /var/log is tmpfs on Unraid - it is wiped on reboot.
# This script reboots at the end, so log to the persistent flash drive instead.
LOG_FILE="/boot/logs/migrate_appdirs_to_datasets.log"

########################################
# LOGGING
########################################

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "FATAL: $*"
  exit 1
}

########################################
# GLOBAL TEMP FILE REGISTRY
# All mktemp calls register here. A single EXIT trap cleans everything up,
# regardless of whether we exit via die(), set -e, or normal completion.
########################################

_TMPFILES=()

_cleanup_tmpfiles() {
  [[ ${#_TMPFILES[@]} -gt 0 ]] && rm -f "${_TMPFILES[@]}" 2>/dev/null || true
}
trap _cleanup_tmpfiles EXIT

make_tmp() {
  local f
  f="$(mktemp)"
  _TMPFILES+=("$f")
  printf '%s' "$f"
}

########################################
# LOCKING
########################################

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  die "Another instance appears to be running (lock: $LOCK_FILE)"
fi

########################################
# PRECHECKS
########################################

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

for cmd in \
  zfs rsync find sha256sum sort cmp awk sed flock sync mv rm readlink \
  stat du wc grep sleep date dirname basename mktemp touch docker shutdown \
  pgrep pkill mount cat chown chmod; do
  require_cmd "$cmd"
done

[[ -x /etc/rc.d/rc.docker ]] || die "/etc/rc.d/rc.docker not found or not executable"
[[ "$(id -u)" -eq 0 ]] || die "Must be run as root"

# Check necessary flags availability
if ! echo -n "" | sha256sum -z >/dev/null 2>&1; then
  die "sha256sum does not support -z flag; coreutils too old"
fi
if ! printf 'a\0' | sort -z >/dev/null 2>&1; then
  die "sort does not support -z flag"
fi

dataset_exists() {
  local ds="$1"
  zfs list -H -o name "$ds" >/dev/null 2>&1
}

for ds in "${PARENT_DATASETS[@]}"; do
  dataset_exists "$ds" || die "Parent dataset does not exist: $ds"
done

dataset_exists "$POOL_NAME" || die "Pool/dataset does not exist: $POOL_NAME"

########################################
# UNRAID SAFETY PRECHECKS
########################################

# Parity check detection
if grep -qE 'mdResync|check' /proc/mdstat 2>/dev/null; then
  die "A parity check or sync is currently running. Stop it before proceeding."
fi

# Mover detection
if pgrep -x mover >/dev/null 2>&1; then
  die "Unraid mover is currently running. Wait for it to finish or disable the schedule and try again."
fi

########################################
# STATE
########################################

MOVED_ANY=0
DOCKER_WAS_RUNNING=0

########################################
# HELPERS
########################################

dataset_to_path() {
  local ds="$1"
  printf '/mnt/%s\n' "$ds"
}

docker_daemon_is_running() {
  /etc/rc.d/rc.docker status >/dev/null 2>&1
}

containers_are_running() {
  [[ -n "$(docker ps -q 2>/dev/null)" ]]
}

# Stop docker containers gracefully, do not stop dockerd
stop_docker() {
  if docker_daemon_is_running; then
    DOCKER_WAS_RUNNING=1
    log "Stopping all running containers..."
    local -a running_ids
    mapfile -t running_ids < <(docker ps -q 2>/dev/null) || true
    if [[ ${#running_ids[@]} -gt 0 ]]; then
      # Request containers to stop
      docker stop "${running_ids[@]}" 2>/dev/null || true
      log "Waiting for containers to exit..."
      # Wait indefinitely until no containers are running
      while containers_are_running; do
        log "Some containers are still running; waiting..."
        sleep 10
      done
    fi
    log "Containers stopped. Leaving dockerd running."
  else
    log "Docker daemon already stopped."
    if containers_are_running; then
      die "Docker daemon is down but containers are somehow still listed. Aborting."
    fi
  fi
}

is_plain_directory() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  [[ ! -L "$path" ]] || return 1
  return 0
}

is_temp_migration_dir() {
  local name="$1"
  [[ "$name" == *".__migration_tmp__."* ]]
}

make_unique_temp_name() {
  local dir="$1"
  local base uid
  base="$(basename "$dir")"
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    uid="$(cat /proc/sys/kernel/random/uuid)"
  else
    uid="$(date +%s).$$.$RANDOM"
  fi
  printf '%s.__migration_tmp__.%s\n' "$base" "$uid"
}

get_pool_available_bytes() {
  zfs list -H -p -o avail "$POOL_NAME" | awk 'NR==1 {print $1}'
}

get_directory_used_bytes() {
  local dir="$1"
  du -skx -- "$dir" | awk '{print $1 * 1024}'
}

calculate_required_free_bytes() {
  local source_bytes="$1"
  local percent_margin safety_margin
  percent_margin=$(( source_bytes * PERCENT_SAFETY_MARGIN / 100 ))
  if (( percent_margin >= ABSOLUTE_SAFETY_MARGIN )); then
    safety_margin="$percent_margin"
  else
    safety_margin="$ABSOLUTE_SAFETY_MARGIN"
  fi
  echo $(( source_bytes + safety_margin ))
}

wait_for_free_space() {
  local required_bytes="$1"
  local label="$2"
  local attempt=0
  while true; do
    local avail
    avail="$(get_pool_available_bytes)"
    [[ "$avail" =~ ^[0-9]+$ ]] || die "Unable to read available space from ZFS pool '$POOL_NAME'"
    if (( avail >= required_bytes )); then
      log "Sufficient free space for '$label': required=${required_bytes} avail=${avail}"
      return 0
    fi
    attempt=$(( attempt + 1 ))
    log "Insufficient free space for '$label' (attempt $attempt): required=${required_bytes} avail=${avail}"
    log "Waiting ${SPACE_RECHECK_SECONDS}s for snapshots/cleanup to free space..."
    sleep "$SPACE_RECHECK_SECONDS"
  done
}

assert_no_sockets() {
  local dir="$1"
  local sockets
  sockets="$(find "$dir" -xdev -type s 2>/dev/null)" || true
  if [[ -n "$sockets" ]]; then
    log "Socket files found under '$dir':"
    log "$sockets"
    die "Refusing to migrate '$dir' while socket files are present (is Docker fully stopped?)."
  fi
}

assert_path_is_mountpoint_for_dataset() {
  local ds="$1"
  local expected_path="$2"
  local actual_mountpoint
  actual_mountpoint="$(zfs get -H -o value mountpoint "$ds")"
  [[ "$actual_mountpoint" == "$expected_path" ]] \
    || die "Dataset '$ds' mountpoint mismatch. Expected '$expected_path', got '$actual_mountpoint'"
  [[ -d "$expected_path" ]] \
    || die "Mountpoint directory missing for dataset '$ds': $expected_path"
  local mounted
  mounted="$(zfs get -H -o value mounted "$ds")"
  [[ "$mounted" == "yes" ]] \
    || die "Dataset '$ds' has correct mountpoint property but is not currently mounted."
}

verify_destination_is_empty() {
  local path="$1"
  if find "$path" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    die "Destination path is not empty: $path"
  fi
}

generate_file_manifest() {
  local root="$1"
  (
    cd "$root"
    find . -xdev -type f -print0 \
      | sort -z \
      | while IFS= read -r -d '' f; do
          sha256sum -z -- "$f"
        done
  )
}

generate_symlink_manifest() {
  local root="$1"
  (
    cd "$root"
    find . -xdev -type l -print0 \
      | sort -z \
      | while IFS= read -r -d '' lnk; do
          printf '%s\0%s\0' "$lnk" "$(readlink -- "$lnk")"
        done
  )
}

compare_manifests() {
  local src="$1"
  local dst="$2"
  local tmp_src_files tmp_dst_files tmp_src_links tmp_dst_links
  tmp_src_files="$(make_tmp)"
  tmp_dst_files="$(make_tmp)"
  tmp_src_links="$(make_tmp)"
  tmp_dst_links="$(make_tmp)"
  log "Generating SHA-256 manifest for source: $src"
  generate_file_manifest "$src" > "$tmp_src_files"
  log "Generating SHA-256 manifest for destination: $dst"
  generate_file_manifest "$dst" > "$tmp_dst_files"
  cmp -s "$tmp_src_files" "$tmp_dst_files" \
    || die "Regular file SHA-256 manifest mismatch between '$src' and '$dst'"
  log "Generating symlink manifest for source: $src"
  generate_symlink_manifest "$src" > "$tmp_src_links"
  log "Generating symlink manifest for destination: $dst"
  generate_symlink_manifest "$dst" > "$tmp_dst_links"
  cmp -s "$tmp_src_links" "$tmp_dst_links" \
    || die "Symlink manifest mismatch between '$src' and '$dst'"
}

compare_counts() {
  local src="$1"
  local dst="$2"
  local src_files dst_files src_dirs dst_dirs src_links dst_links
  src_files="$(find "$src" -xdev -type f | wc -l)"
  dst_files="$(find "$dst" -xdev -type f | wc -l)"
  [[ "$src_files" == "$dst_files" ]] \
    || die "Regular file count mismatch: source=$src_files dest=$dst_files"
  src_dirs="$(find "$src" -xdev -type d | wc -l)"
  dst_dirs="$(find "$dst" -xdev -type d | wc -l)"
  [[ "$src_dirs" == "$dst_dirs" ]] \
    || die "Directory count mismatch: source=$src_dirs dest=$dst_dirs"
  src_links="$(find "$src" -xdev -type l | wc -l)"
  dst_links="$(find "$dst" -xdev -type l | wc -l)"
  [[ "$src_links" == "$dst_links" ]] \
    || die "Symlink count mismatch: source=$src_links dest=$dst_links"
}

rsync_copy() {
  local src="$1"
  local dst="$2"
  log "Copying '$src' -> '$dst'"
  rsync -aHAX --numeric-ids --human-readable --info=progress2 \
    "$src"/ "$dst"/
}

rsync_verify() {
  local src="$1"
  local dst="$2"
  local verify_out
  verify_out="$(make_tmp)"
  log "Running rsync checksum verification: '$src' vs '$dst'"
  rsync -aHAXcn --delete --numeric-ids --itemize-changes \
    "$src"/ "$dst"/ > "$verify_out" 2>&1
  if [[ -s "$verify_out" ]]; then
    log "Rsync reported the following differences:"
    cat "$verify_out"
    die "Rsync checksum verification reported differences between '$src' and '$dst' (see above)"
  fi
}

migrate_one_directory() {
  local parent_ds="$1"
  local parent_path="$2"
  local entry_path="$3"
  local name child_ds temp_name temp_path new_path
  local source_bytes required_bytes
  name="$(basename "$entry_path")"
  child_ds="${parent_ds}/${name}"
  new_path="${parent_path}/${name}"
  log "------------------------------------------------------------"
  log "Processing: $entry_path"
  log "Target dataset: $child_ds"
  if is_temp_migration_dir "$name"; then
    log "WARNING: Skipping leftover temp directory from a previous crashed run: $entry_path"
    log "         Inspect this directory manually. If it is a complete copy,"
    log "         rename it back to its original name and re-run this script."
    log "         If it is corrupt or incomplete, delete it and re-run."
    return 0
  fi
  if dataset_exists "$child_ds"; then
    log "SKIP: already a dataset -> $child_ds"
    return 0
  fi
  is_plain_directory "$entry_path" || {
    log "SKIP: not a plain directory -> $entry_path"
    return 0
  }
  [[ "$name" != *"/"* ]] || die "Unexpected slash in child name: $name"
  [[ "$name" != "." && "$name" != ".." ]] || die "Unsafe child name: $name"
  assert_no_sockets "$entry_path"
  source_bytes="$(get_directory_used_bytes "$entry_path")"
  [[ "$source_bytes" =~ ^[0-9]+$ ]] || die "Could not determine source size for '$entry_path'"
  required_bytes="$(calculate_required_free_bytes "$source_bytes")"
  wait_for_free_space "$required_bytes" "$entry_path"
  temp_name="$(make_unique_temp_name "$entry_path")"
  temp_path="${parent_path}/${temp_name}"
  [[ ! -e "$temp_path" ]] || die "Temp path already exists: $temp_path"
  [[ ! -e "$new_path" ]] || die "Expected target path to not exist before rename: $new_path"
  log "Renaming source directory:"
  log "  from: $entry_path"
  log "  to  : $temp_path"
  mv -- "$entry_path" "$temp_path"
  [[ -d "$temp_path" ]] || die "Temp source directory missing after rename: $temp_path"
  [[ ! -e "$new_path" ]] || die "Original path unexpectedly still exists after rename: $new_path"
  wait_for_free_space "$required_bytes" "$temp_path"
  log "Creating dataset: $child_ds"
  zfs create "$child_ds"
  dataset_exists "$child_ds" || die "Dataset creation failed: $child_ds"
  assert_path_is_mountpoint_for_dataset "$child_ds" "$new_path"
  verify_destination_is_empty "$new_path"
  # Preserve top-level metadata (owner/group/mode/modtime) on new dataset root.
  chown --reference="$temp_path" "$new_path"
  chmod --reference="$temp_path" "$new_path"
  touch --reference="$temp_path" "$new_path"
  rsync_copy "$temp_path" "$new_path"
  sync
  rsync_verify "$temp_path" "$new_path"
  compare_manifests "$temp_path" "$new_path"
  compare_counts "$temp_path" "$new_path"
  [[ -d "$new_path" ]] || die "New dataset mountpoint vanished after copy: $new_path"
  dataset_exists "$child_ds" || die "New dataset disappeared after copy: $child_ds"
  log "All verification passed for: $name"
  log "Deleting temp source: $temp_path"
  rm -rf --one-file-system -- "$temp_path"
  [[ ! -e "$temp_path" ]] || die "Temp source still exists after deletion: $temp_path"
  MOVED_ANY=1
  log "Migration complete for: $name"
}

########################################
# MAIN
########################################

log "===== Starting dataset migration ====="
log "Log file: $LOG_FILE"
stop_docker
for parent_ds in "${PARENT_DATASETS[@]}"; do
  parent_path="$(dataset_to_path "$parent_ds")"
  [[ -d "$parent_path" ]] || die "Parent path missing: $parent_path"
  assert_path_is_mountpoint_for_dataset "$parent_ds" "$parent_path"
  log "Scanning parent dataset: $parent_ds"
  log "Scanning path          : $parent_path"
  # Process one directory at a time so each migration fully completes
  # including temp deletion, before the next one begins.
  find "$parent_path" -mindepth 1 -maxdepth 1 -type d -print0 |
  while IFS= read -r -d '' child; do
    migrate_one_directory "$parent_ds" "$parent_path" "$child"
  done
done
if [[ "$MOVED_ANY" -eq 1 ]]; then
  log "At least one migration occurred."
  log "Issuing final sync..."
  sync
  log "Waiting ${REBOOT_WAIT_SECONDS} seconds before reboot..."
  _remain="$REBOOT_WAIT_SECONDS"
  _tick=10
  while (( _remain > 0 )); do
    log "Rebooting in ${_remain}s..."
    if (( _remain >= _tick )); then
      sleep "$_tick"
      _remain=$(( _remain - _tick ))
    else
      sleep "$_remain"
      _remain=0
    fi
  done
  log "Rebooting now via shutdown -r (clean Unraid array teardown)."
  /sbin/shutdown -r now
else
  log "No migrations were needed. No reboot will be performed."
fi
log "===== Script finished ====="
exit 0
