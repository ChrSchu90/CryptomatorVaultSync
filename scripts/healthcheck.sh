#!/usr/bin/env bash
set -Eeuo pipefail

SYNC_CRON="${SYNC_CRON:-}"
STATE_DIR="${STATE_DIR:-/state}"

# One-shot mode: the container exits after sync anyway, the container exit code is the health signal.
if [[ -z "$SYNC_CRON" ]]; then
  exit 0
fi

# If no status file exists yet, do not mark the container unhealthy, this can happen during startup before the first sync cycle writes state.
if [[ ! -f "$STATE_DIR/current-status" ]]; then
  exit 0
fi

current_status="$(cat "$STATE_DIR/current-status" 2>/dev/null || true)"
current_status_value="$(printf '%s\n' "$current_status" | awk 'NF {print $NF; exit}')"

case "$current_status_value" in
  starting|running|idle|stopped)
    exit 0
    ;;
  *)
    echo "current status is not healthy: ${current_status:-empty}"
    exit 1
    ;;
esac
