#!/usr/bin/env bash
set -euo pipefail

load_config_defaults() {
  DRY_RUN="${DRY_RUN:-false}"
  SYNC_CRON="${SYNC_CRON:-}"

  SYNC_DIR="${SYNC_DIR:-/sync}"
  STATE_DIR="${STATE_DIR:-/state}"

  MOUNT_TIMEOUT_SECONDS="${MOUNT_TIMEOUT_SECONDS:-60}"
  VAULT_ENCRYPTED_DIR="${VAULT_ENCRYPTED_DIR:-/vault-encrypted}"
  VAULT_DECRYPTED_DIR="${VAULT_DECRYPTED_DIR:-/vault-decrypted}"
  VAULT_DECRYPTED_BASE_DEV="${VAULT_DECRYPTED_BASE_DEV:-}"
  VAULT_PASSWORD="${VAULT_PASSWORD:-}"

  CRYPTOMATOR_MOUNT_MODE="${CRYPTOMATOR_MOUNT_MODE:-auto}"

  RSYNC_DELETE="${RSYNC_DELETE:-false}"
  RSYNC_EXCLUDE_FILE="${RSYNC_EXCLUDE_FILE:-}"
  RSYNC_ARGS="${RSYNC_ARGS:--rtvi --no-owner --no-group --no-perms}"
  RSYNC_EXTRA_ARGS="${RSYNC_EXTRA_ARGS:-}"

  UPSTREAM_ENABLED="${UPSTREAM_ENABLED:-false}"
  UPSTREAM_FAIL_ACTION="${UPSTREAM_FAIL_ACTION:-exit}"
  UPSTREAM_MODE="${UPSTREAM_MODE:-sync}"
  UPSTREAM_DESTINATIONS="${UPSTREAM_DESTINATIONS:-}"
  UPSTREAM_CONFIG="${UPSTREAM_CONFIG:-/config/rclone.conf}"
  UPSTREAM_EXTRA_ARGS="${UPSTREAM_EXTRA_ARGS:-}"
  UPSTREAM_START_DELAY_SECONDS="${UPSTREAM_START_DELAY_SECONDS:-0}"
}

require_dir() {
  local dir="$1"
  local name="$2"

  if [[ ! -d "$dir" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "$name does not exist: $dir"
  fi
}

require_cryptomator_vault() {
  local dir="$1"

  if [[ ! -f "$dir/vault.cryptomator" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "missing vault.cryptomator in encrypted vault dir: $dir"
  fi

  if [[ ! -f "$dir/masterkey.cryptomator" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "missing masterkey.cryptomator in encrypted vault dir: $dir"
  fi

  if [[ ! -d "$dir/d" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "missing encrypted data directory 'd' in encrypted vault dir: $dir"
  fi
}

require_empty_mountpoint() {
  mkdir -p "$VAULT_DECRYPTED_DIR"

  if find "$VAULT_DECRYPTED_DIR" -mindepth 1 -maxdepth 1 | read -r; then
    exit_failed "$EXIT_CONFIG_ERROR" "vault decrypted dir must be empty: $VAULT_DECRYPTED_DIR"
  fi

  VAULT_DECRYPTED_BASE_DEV="$(stat -c '%d' "$VAULT_DECRYPTED_DIR")"
  log_info "Base device for decrypted vault dir: $VAULT_DECRYPTED_BASE_DEV"
}

has_valid_upstream_destination() {
  local destination=""
  local destinations=()

  IFS='|' read -r -a destinations <<< "$UPSTREAM_DESTINATIONS"

  for destination in "${destinations[@]}"; do
    destination="$(trim "$destination")"

    if [[ -n "$destination" ]]; then
      return 0
    fi
  done

  return 1
}

validate_cron_expression() {
  if [[ -z "$SYNC_CRON" ]]; then
    return 0
  fi

  if [[ "$SYNC_CRON" == *$'\n'* || "$SYNC_CRON" == *$'\r'* ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "SYNC_CRON must not contain line breaks"
  fi

  local fields=()
  read -r -a fields <<< "$SYNC_CRON"

  if [[ "${#fields[@]}" -ne 5 ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "SYNC_CRON must use the standard 5-field format, for example: */5 * * * *"
  fi
}

validate_config() {
  if [[ -n "${SYNC_INTERVAL_MINUTES+x}" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "SYNC_INTERVAL_MINUTES has been removed. Use SYNC_CRON instead. Leave SYNC_CRON empty for one-shot mode."
  fi

  validate_cron_expression

  if [[ -z "${CRYPTOMATOR_VAULT_PASSWORD:-}" && -z "${CRYPTOMATOR_VAULT_PASSWORD_FILE:-}" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "CRYPTOMATOR_VAULT_PASSWORD or CRYPTOMATOR_VAULT_PASSWORD_FILE is required"
  fi

  if [[ -z "${CRYPTOMATOR_VAULT_PASSWORD:-}" && -n "${CRYPTOMATOR_VAULT_PASSWORD_FILE:-}" ]]; then
    if [[ ! -f "$CRYPTOMATOR_VAULT_PASSWORD_FILE" ]]; then
      exit_failed "$EXIT_CONFIG_ERROR" "CRYPTOMATOR_VAULT_PASSWORD_FILE does not exist: $CRYPTOMATOR_VAULT_PASSWORD_FILE"
    fi

    if [[ ! -r "$CRYPTOMATOR_VAULT_PASSWORD_FILE" ]]; then
      exit_failed "$EXIT_CONFIG_ERROR" "CRYPTOMATOR_VAULT_PASSWORD_FILE is not readable: $CRYPTOMATOR_VAULT_PASSWORD_FILE"
    fi

    if [[ ! -s "$CRYPTOMATOR_VAULT_PASSWORD_FILE" ]]; then
      exit_failed "$EXIT_CONFIG_ERROR" "CRYPTOMATOR_VAULT_PASSWORD_FILE is empty: $CRYPTOMATOR_VAULT_PASSWORD_FILE"
    fi
  fi

  case "$CRYPTOMATOR_MOUNT_MODE" in
    fuse|webdav|auto)
      ;;
    *)
      exit_failed "$EXIT_CONFIG_ERROR" "Invalid CRYPTOMATOR_MOUNT_MODE: $CRYPTOMATOR_MOUNT_MODE. Allowed values: fuse, webdav, auto"
      ;;
  esac

  case "$UPSTREAM_FAIL_ACTION" in
    exit|continue)
      ;;
    *)
      exit_failed "$EXIT_CONFIG_ERROR" "Invalid UPSTREAM_FAIL_ACTION: $UPSTREAM_FAIL_ACTION. Allowed values: exit, continue"
      ;;
  esac

  if [[ "$DRY_RUN" != "true" && "$DRY_RUN" != "false" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "DRY_RUN must be true or false"
  fi

  if [[ "$RSYNC_DELETE" != "true" && "$RSYNC_DELETE" != "false" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "RSYNC_DELETE must be true or false"
  fi

  if [[ -n "${RSYNC_EXCLUDE_FILE:-}" ]]; then
    if [[ ! -f "$RSYNC_EXCLUDE_FILE" ]]; then
      exit_failed "$EXIT_CONFIG_ERROR" "RSYNC_EXCLUDE_FILE does not exist: $RSYNC_EXCLUDE_FILE"
    fi

    if [[ ! -r "$RSYNC_EXCLUDE_FILE" ]]; then
      exit_failed "$EXIT_CONFIG_ERROR" "RSYNC_EXCLUDE_FILE is not readable: $RSYNC_EXCLUDE_FILE"
    fi
  fi

  if ! [[ "$MOUNT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$MOUNT_TIMEOUT_SECONDS" == "0" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "MOUNT_TIMEOUT_SECONDS must be a positive integer"
  fi

  if [[ "$UPSTREAM_ENABLED" != "true" && "$UPSTREAM_ENABLED" != "false" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "UPSTREAM_ENABLED must be true or false"
  fi

  if [[ "$UPSTREAM_ENABLED" == "true" ]]; then
    if ! has_valid_upstream_destination; then
      exit_failed "$EXIT_CONFIG_ERROR" "UPSTREAM_DESTINATIONS is required when UPSTREAM_ENABLED=true"
    fi

    if [[ ! -f "$UPSTREAM_CONFIG" ]]; then
      exit_failed "$EXIT_CONFIG_ERROR" "Rclone config does not exist: $UPSTREAM_CONFIG"
    fi

    if ! [[ "$UPSTREAM_START_DELAY_SECONDS" =~ ^[0-9]+$ ]]; then
      exit_failed "$EXIT_CONFIG_ERROR" "UPSTREAM_START_DELAY_SECONDS must be a non-negative integer"
    fi

    case "$UPSTREAM_MODE" in
      sync|copy)
        ;;
      *)
        exit_failed "$EXIT_CONFIG_ERROR" "Invalid UPSTREAM_MODE: $UPSTREAM_MODE. Allowed values: sync, copy"
        ;;
    esac
  fi
}

validate_sync_runtime() {
  require_dir "$SYNC_DIR" "sync dir"
  require_dir "$VAULT_ENCRYPTED_DIR" "encrypted vault dir"
  require_cryptomator_vault "$VAULT_ENCRYPTED_DIR"
  require_empty_mountpoint
}

load_password() {
  if [[ -n "${CRYPTOMATOR_VAULT_PASSWORD:-}" ]]; then
    VAULT_PASSWORD="$CRYPTOMATOR_VAULT_PASSWORD"
    unset CRYPTOMATOR_VAULT_PASSWORD
    unset CRYPTOMATOR_VAULT_PASSWORD_FILE
    return 0
  fi

  VAULT_PASSWORD="$(cat "$CRYPTOMATOR_VAULT_PASSWORD_FILE")"
  unset CRYPTOMATOR_VAULT_PASSWORD_FILE

  if [[ -z "$VAULT_PASSWORD" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "Vault password is empty"
  fi
}
