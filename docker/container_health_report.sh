#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: container_health_report.sh [--fail-on-issues]

Print a compact Docker container health report.

Options:
  --fail-on-issues   Exit with status 1 if any container is not running or is unhealthy
EOF
}

FAIL_ON_ISSUES=0

if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi

if [[ $# -eq 1 ]]; then
  case "$1" in
    --fail-on-issues)
      FAIL_ON_ISSUES=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
fi

command -v docker >/dev/null 2>&1 || {
  echo "docker command not found"
  exit 1
}

containers="$(docker ps -a --format '{{.Names}}' || true)"
if [[ -z "$containers" ]]; then
  echo "No Docker containers found."
  exit 0
fi

issues=0

printf '%-30s %-12s %-12s %-10s %s\n' "CONTAINER" "STATE" "HEALTH" "RESTARTS" "NETWORK"
printf '%-30s %-12s %-12s %-10s %s\n' "---------" "-----" "------" "--------" "-------"

while IFS= read -r container; do
  [[ -z "$container" ]] && continue

  inspect="$(
    docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.HostConfig.NetworkMode}}' "$container" 2>/dev/null || true
  )"

  if [[ -z "$inspect" ]]; then
    printf '%-30s %-12s %-12s %-10s %s\n' "$container" "unknown" "unknown" "?" "?"
    issues=$((issues + 1))
    continue
  fi

  IFS='|' read -r state health restart_count network_mode <<< "$inspect"
  printf '%-30s %-12s %-12s %-10s %s\n' "$container" "$state" "$health" "$restart_count" "$network_mode"

  if [[ "$state" != "running" || "$health" == "unhealthy" ]]; then
    issues=$((issues + 1))
  fi
done <<< "$containers"

if (( issues > 0 )); then
  echo
  echo "Issues detected: $issues"
fi

if (( FAIL_ON_ISSUES == 1 && issues > 0 )); then
  exit 1
fi
