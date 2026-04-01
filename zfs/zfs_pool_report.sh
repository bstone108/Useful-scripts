#!/bin/bash
set -euo pipefail

TOP_N="${TOP_N:-10}"

if ! [[ "$TOP_N" =~ ^[0-9]+$ ]] || (( TOP_N < 1 )); then
  echo "TOP_N must be a positive integer"
  exit 1
fi

command -v zpool >/dev/null 2>&1 || {
  echo "zpool command not found"
  exit 1
}

command -v zfs >/dev/null 2>&1 || {
  echo "zfs command not found"
  exit 1
}

pools="$(zpool list -H -o name || true)"
if [[ -z "$pools" ]]; then
  echo "No ZFS pools found."
  exit 0
fi

echo "ZFS pool report generated at $(date)"
echo

while IFS= read -r pool; do
  [[ -z "$pool" ]] && continue

  read -r name size alloc free cap health frag <<< "$(zpool list -H -o name,size,alloc,free,cap,health,fragmentation "$pool")"
  freeing="$(zpool get -H -o value freeing "$pool" 2>/dev/null || true)"
  [[ -n "$freeing" ]] || freeing="-"

  echo "Pool: $name"
  echo "  Size:          $size"
  echo "  Allocated:     $alloc"
  echo "  Free:          $free"
  echo "  Capacity:      $cap"
  echo "  Health:        $health"
  echo "  Fragmentation: $frag"
  echo "  Freeing:       $freeing"
  echo
  echo "Top ${TOP_N} datasets by used space:"

  zfs list -H -r -t filesystem,volume -o name,used,avail,refer,mountpoint -S used "$pool" |
    head -n "$TOP_N" |
    awk -F '\t' '
      BEGIN {
        printf "%-36s %-10s %-10s %-10s %s\n", "DATASET", "USED", "AVAIL", "REFER", "MOUNTPOINT"
      }
      {
        printf "%-36s %-10s %-10s %-10s %s\n", $1, $2, $3, $4, $5
      }
    '

  echo
done <<< "$pools"
