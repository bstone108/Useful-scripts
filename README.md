# Useful Scripts

A growing collection of shell scripts that are useful for day-to-day server, Docker, ZFS, and Unraid administration.

Most scripts in this repo are written to work well on Unraid, but the goal is broader than that: if a script is useful on regular Linux too and stays compatible with Unraid, it belongs here.

## Layout

- `unraid/`
  Unraid-specific maintenance and automation scripts.
- `docker/`
  Docker helpers that also work fine on Unraid.
- `zfs/`
  ZFS helpers that are compatible with Unraid's native ZFS support.

## Current Scripts

| Path | What it does |
| --- | --- |
| `unraid/gluetun_healthcheck.sh` | Checks containers tied to a Gluetun container network, starts stopped dependents, and restarts containers that appear to have lost outbound connectivity. |
| `unraid/gpu_power_enforcer.sh` | Re-applies a target NVIDIA GPU power limit and persistence mode if the card drifts from the desired state. |
| `unraid/migrate_appdirs_to_datasets.sh` | Migrates plain directories under selected parent datasets into child ZFS datasets with safety checks, verification, and cleanup. |
| `unraid/zfs_autosnapshot.sh` | Legacy ZFS autosnapshot script for Unraid. Deprecated in favor of the plugin at `https://github.com/bstone108/zfsautosnapshot-unraid`. |
| `docker/container_health_report.sh` | Prints a compact report of Docker container state, health, restart count, and network mode. Can optionally exit non-zero when issues are found. |
| `zfs/create_test_autosnapshots.sh` | Creates a configurable number of test snapshots on a dataset using `autosnapshot-YYYY-MM-DD_HH-MM-SS` style names for plugin testing. |
| `zfs/zfs_pool_report.sh` | Shows a quick ZFS pool summary plus the largest datasets in each pool. |

## Usage

- Review each script before running it.
- Many scripts are intended to run as `root`, especially on Unraid.
- Most scripts can be run directly from a shell or from the Unraid User Scripts plugin.
- Mark new scripts executable with `chmod +x` if you copy them elsewhere.

## Notes

- Scripts are organized by what they are for, not just by platform.
- If a script becomes deprecated, the file should say so near the top and point to the preferred replacement.
- Safer, read-only utilities are preferred unless an active fix or maintenance action is the whole point of the script.
