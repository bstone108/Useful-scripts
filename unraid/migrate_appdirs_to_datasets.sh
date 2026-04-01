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
# EXIT HANDLING
########################################

REBOOT_REQUIRED=0
REBOOT_REQUESTED=0

request_reboot() {
  local reason="$1"
  local remain tick

  if (( REBOOT_REQUESTED == 1 )); then
    return 0
  fi

  REBOOT_REQUESTED=1
  log "$reason"
  log "Waiting ${REBOOT_WAIT_SECONDS} seconds before reboot..."

  remain="$REBOOT_WAIT_SECONDS"
  tick=10
  while (( remain > 0 )); do
    log "Rebooting in ${remain}s..."
    if (( remain >= tick )); then
      sleep "$tick"
      remain=$(( remain - tick ))
    else
      sleep "$remain"
      remain=0
    fi
  done

  log "Rebooting now via shutdown -r (clean Unraid array teardown)."
  /sbin/shutdown -r now || \
    log "WARNING: shutdown -r now failed. Reboot manually before re-enabling Docker autostart."
}

_on_exit() {
  local status=$?

  if (( status != 0 )) && (( REBOOT_REQUIRED == 1 )) && (( REBOOT_REQUESTED == 0 )); then
    log "A failure occurred after at least one child dataset was created."
    log "A clean reboot is still required so Unraid can register manually created datasets."
    request_reboot "Proceeding with the normal reboot delay despite the failure."
  fi

  return "$status"
}
trap _on_exit EXIT

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

find_mdcmd() {
  if command -v mdcmd >/dev/null 2>&1; then
    command -v mdcmd
    return 0
  fi

  [[ -x /root/mdcmd ]] || return 1
  printf '/root/mdcmd\n'
}

extract_status_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { print $2; exit }'
}

get_unraid_array_status() {
  local mdcmd_bin

  if mdcmd_bin="$(find_mdcmd 2>/dev/null)"; then
    "$mdcmd_bin" status
    return 0
  fi

  if [[ -r /proc/mdcmd ]]; then
    cat /proc/mdcmd
    return 0
  fi

  if [[ -r /var/local/emhttp/var.ini ]]; then
    cat /var/local/emhttp/var.ini
    return 0
  fi

  return 1
}

parity_sync_in_progress() {
  local status_text mdresync mdaction mdstat_line

  status_text="$(get_unraid_array_status 2>/dev/null || true)"
  if [[ -n "$status_text" ]]; then
    mdresync="$(printf '%s\n' "$status_text" | extract_status_value "mdResync")"
    mdaction="$(printf '%s\n' "$status_text" | extract_status_value "mdResyncAction")"

    if [[ "$mdresync" =~ ^[0-9]+$ ]] && (( mdresync > 0 )); then
      log "Detected array sync activity: mdResync=$mdresync mdResyncAction='${mdaction:-unknown}'"
      return 0
    fi

    return 1
  fi

  mdstat_line="$(grep -m 1 -E '(^|[[:space:]])(resync|recovery|reshape|check)[[:space:]]*=' /proc/mdstat 2>/dev/null || true)"
  if [[ -n "$mdstat_line" ]]; then
    log "Detected array sync activity from /proc/mdstat fallback: $mdstat_line"
    return 0
  fi

  return 1
}

mover_process_matches() {
  local args="$1"
  [[ "$args" == *"/usr/local/sbin/mover"* ]] || [[ "$args" == *"/usr/local/bin/mover"* ]]
}

mover_is_running() {
  local pidfile="/var/run/mover.pid"
  local pid args line

  if [[ -r "$pidfile" ]]; then
    pid="$(<"$pidfile")"
    pid="${pid//[[:space:]]/}"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
      if [[ -n "$args" ]] && mover_process_matches "$args"; then
        log "Detected running mover via $pidfile: pid=$pid args=$args"
        return 0
      fi
    fi
  fi

  while IFS= read -r line; do
    IFS=' ' read -r pid args <<< "$line"
    if [[ -n "$args" ]] && mover_process_matches "$args"; then
      log "Detected running mover via process list: pid=$pid args=$args"
      return 0
    fi
  done < <(ps -eo pid=,args= 2>/dev/null)

  return 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

for cmd in \
  zfs rsync find sha256sum sort cmp awk sed flock sync mv rm readlink \
  stat du wc grep sleep date dirname basename touch docker shutdown \
  cat chown chmod ps; do
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
if parity_sync_in_progress; then
  die "A parity check or sync is currently running. Stop it before proceeding."
fi

# Mover detection
if mover_is_running; then
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

container_running_state() {
  local container_id="$1"
  docker inspect -f '{{.State.Running}}|{{.Name}}|{{.State.Status}}' "$container_id" 2>/dev/null || true
}

list_running_containers_for_ids() {
  local container_id inspect running name status

  for container_id in "$@"; do
    [[ -n "$container_id" ]] || continue

    inspect="$(container_running_state "$container_id")"
    [[ -n "$inspect" ]] || continue

    IFS='|' read -r running name status <<< "$inspect"
    [[ "$running" == "true" ]] || continue

    printf '%s\t%s\t%s\n' "$container_id" "${name#/}" "$status"
  done
}

list_running_containers() {
  local -a all_ids

  mapfile -t all_ids < <(docker ps -aq 2>/dev/null || true)
  list_running_containers_for_ids "${all_ids[@]}"
}

log_running_container_lines() {
  local line

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    log "  $line"
  done
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
      docker stop "${running_ids[@]}" >/dev/null 2>&1 || true
      log "Waiting for containers to exit..."

      while :; do
        local remaining
        remaining="$(list_running_containers_for_ids "${running_ids[@]}")"
        [[ -z "$remaining" ]] && break

        log "Some targeted containers are still reported as running:"
        log_running_container_lines <<< "$remaining"
        sleep 10
      done
    fi

    local running_now
    running_now="$(list_running_containers)"
    if [[ -n "$running_now" ]]; then
      log "Docker still reports running containers after stop:"
      log_running_container_lines <<< "$running_now"
      die "Refusing to continue while Docker containers are running."
    fi

    log "Containers stopped. Leaving dockerd running."
  else
    log "Docker daemon already stopped."
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

assert_no_nested_mounts() {
  local dir="$1"
  local root_dev offender

  root_dev="$(stat -c '%d' "$dir")"
  offender="$(
    find "$dir" -mindepth 1 -type d -exec stat --printf '%d\t%n\0' -- {} + 2>/dev/null |
      awk -v RS='\0' -F '\t' -v root_dev="$root_dev" '$1 != root_dev { print $2; exit }'
  )"

  if [[ -n "$offender" ]]; then
    die "Nested mount or child dataset detected under '$dir': $offender"
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
  log "Generating SHA-256 manifest for source: $src"
  log "Generating SHA-256 manifest for destination: $dst"
  cmp -s <(generate_file_manifest "$src") <(generate_file_manifest "$dst") \
    || die "Regular file SHA-256 manifest mismatch between '$src' and '$dst'"
  log "Generating symlink manifest for source: $src"
  log "Generating symlink manifest for destination: $dst"
  cmp -s <(generate_symlink_manifest "$src") <(generate_symlink_manifest "$dst") \
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
  rsync -aHAXx --numeric-ids --human-readable --info=progress2 \
    "$src"/ "$dst"/
}

rsync_verify() {
  local src="$1"
  local dst="$2"
  local line had_differences=0 rsync_status=
  log "Running rsync checksum verification: '$src' vs '$dst'"

  while IFS= read -r line; do
    if [[ "$line" == "__RSYNC_EXIT_STATUS__:"* ]]; then
      rsync_status="${line#__RSYNC_EXIT_STATUS__:}"
      continue
    fi

    if (( had_differences == 0 )); then
      log "Rsync reported the following differences:"
      had_differences=1
    fi
    printf '%s\n' "$line"
  done < <(
    rsync -aHAXcnx --delete --numeric-ids --itemize-changes \
      "$src"/ "$dst"/ 2>&1
    printf '__RSYNC_EXIT_STATUS__:%s\n' "$?"
  )

  [[ "$rsync_status" =~ ^[0-9]+$ ]] || die "Unable to determine rsync verification exit status"
  (( rsync_status == 0 )) || die "Rsync checksum verification failed with exit status $rsync_status"

  if (( had_differences == 1 )); then
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
  assert_no_nested_mounts "$entry_path"
  source_bytes="$(get_directory_used_bytes "$entry_path")"
  [[ "$source_bytes" =~ ^[0-9]+$ ]] || die "Could not determine source size for '$entry_path'"
  required_bytes="$(calculate_required_free_bytes "$source_bytes")"
  wait_for_free_space "$required_bytes" "$entry_path"
  temp_name="$(make_unique_temp_name "$entry_path")"
  temp_path="${parent_path}/${temp_name}"
  [[ ! -e "$temp_path" ]] || die "Temp path already exists: $temp_path"
  [[ "$entry_path" == "$new_path" ]] || die "Internal path mismatch: entry_path='$entry_path' new_path='$new_path'"
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
  REBOOT_REQUIRED=1
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
  while IFS= read -r -d '' child; do
    migrate_one_directory "$parent_ds" "$parent_path" "$child"
  done < <(find "$parent_path" -mindepth 1 -maxdepth 1 -type d -print0)
done
if [[ "$MOVED_ANY" -eq 1 ]]; then
  log "At least one migration occurred."
  log "Issuing final sync..."
  sync
  request_reboot "At least one migration occurred."
else
  log "No migrations were needed. No reboot will be performed."
fi
log "===== Script finished ====="
exit 0
