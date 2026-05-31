#!/usr/bin/env bash
set -Eeuo pipefail

SYNC_INTERVAL_MINUTES="${SYNC_INTERVAL_MINUTES:-0}"
STATE_DIR="${STATE_DIR:-/state}"

case "$SYNC_INTERVAL_MINUTES" in
  ''|*[!0-9]*)
    echo "SYNC_INTERVAL_MINUTES must be a non-negative integer"
    exit 1
    ;;
esac

# One-shot mode: the container exits after sync anyway, the container exit code is the health signal.
if [[ "$SYNC_INTERVAL_MINUTES" == "0" ]]; then
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