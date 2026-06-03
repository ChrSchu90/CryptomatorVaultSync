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

run_scheduled_sync() {
  load_config_defaults
  validate_config

  local status=0

  set +e
  flock -n -E "$EXIT_LOCK_SKIPPED" "$SYNC_LOCK_FILE" /sync.sh
  status="$?"
  set -e

  if [[ "$status" -eq "$EXIT_LOCK_SKIPPED" ]]; then
    log_warn "Previous sync cycle is still running. Skipping this scheduled run."
    return 0
  fi

  return "$status"
}

run_cron() {
  log_info "Cron sync enabled. Schedule: $SYNC_CRON"

  printf '%s /bin/sh -c '\''/run.sh --scheduled-sync || kill -TERM 1'\''\n' "$SYNC_CRON" > "$CRON_FILE"

  trap cleanup_scheduler EXIT
  trap 'cleanup_scheduler; exit "$EXIT_OK"' INT
  trap 'cleanup_scheduler; exit "$EXIT_OK"' TERM

  supercronic "$CRON_FILE" &
  SUPERCRONIC_PID="$!"
  wait "$SUPERCRONIC_PID"
}

main() {
  case "${1:-}" in
    --scheduled-sync)
      run_scheduled_sync
      ;;
    --help|-h)
      printf 'Usage: /run.sh [--scheduled-sync]\n'
      ;;
    *)
      write_status "current-status" "starting"
      validate_config

      if [[ -z "$SYNC_CRON" ]]; then
        exec /sync.sh
      fi

      run_cron
      ;;
  esac
}

main "$@"
