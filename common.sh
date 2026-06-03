#!/usr/bin/env bash

EXIT_OK=0
EXIT_GENERAL_ERROR=1
EXIT_CONFIG_ERROR=2
EXIT_LOCK_SKIPPED=75

EXIT_IS_FAILURE="${EXIT_IS_FAILURE:-false}"

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
}

write_status() {
  local name="$1"
  shift || true
  local message="$*"

  ensure_state_dir

  if [[ -d "$STATE_DIR" && -w "$STATE_DIR" ]]; then
    if [[ -n "$message" ]]; then
      printf '%s %s\n' "$(timestamp)" "$message" > "$STATE_DIR/$name"
    else
      printf '%s\n' "$(timestamp)" > "$STATE_DIR/$name"
    fi
  fi
}

log_info() {
  printf '[%s] \033[94mINF\033[0m: %s\n' "$(timestamp)" "$*"
}

log_warn() {
  printf '[%s] \033[93mWRN\033[0m: %s\n' "$(timestamp)" "$*"
}

log_error() {
  printf '[%s] \033[91mERR\033[0m: %s\n' "$(timestamp)" "$*"
}

exit_failed() {
  local exit_code="$1"
  shift

  EXIT_IS_FAILURE="true"

  log_error "$*"
  write_status "last-error" "$*"
  write_status "current-status" "failed"
  exit "$exit_code"
}
