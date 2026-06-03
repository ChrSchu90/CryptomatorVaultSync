#!/usr/bin/env bash
set -Eeuo pipefail

. /common.sh
. /config.sh

load_config_defaults

SUPERCRONIC_PID=""
CRON_FILE="/tmp/cryptomator-vault-sync.cron"

cleanup_scheduler() {
  trap - EXIT INT TERM

  if [[ -n "$SUPERCRONIC_PID" ]] && kill -0 "$SUPERCRONIC_PID" 2>/dev/null; then
    log_info "Stopping scheduler..."
    kill -TERM "$SUPERCRONIC_PID" 2>/dev/null || true
    wait "$SUPERCRONIC_PID" 2>/dev/null || true
  fi

  if [[ "$EXIT_IS_FAILURE" != "true" ]]; then
    write_status "current-status" "stopped"
  fi
}

run_cron() {
  log_info "Cron sync enabled. Schedule: $SYNC_CRON"

  printf '%s /sync.sh\n' "$SYNC_CRON" > "$CRON_FILE"

  trap cleanup_scheduler EXIT
  trap 'cleanup_scheduler; exit "$EXIT_OK"' INT
  trap 'cleanup_scheduler; exit "$EXIT_OK"' TERM

  supercronic "$CRON_FILE" &
  SUPERCRONIC_PID="$!"
  wait "$SUPERCRONIC_PID"
}

main() {
  write_status "current-status" "starting"
  validate_config

  if [[ -z "$SYNC_CRON" ]]; then
    log_info "One-shot sync enabled."
    exec /sync.sh
  fi

  run_cron
}

main "$@"