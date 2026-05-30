#!/usr/bin/env bash
set -Eeuo pipefail

EXIT_OK=0
EXIT_GENERAL_ERROR=1
EXIT_CONFIG_ERROR=2

SYNC_DIR="${SYNC_DIR:-/sync}"

VAULT_ENCRYPTED_DIR="${VAULT_ENCRYPTED_DIR:-/vault-encrypted}"
VAULT_DECRYPTED_DIR="/vault-decrypted" # The vault-decrypted mount is internally, since the host can not see the content anyways
VAULT_DECRYPTED_BASE_DEV=""
VAULT_PASSWORD=""

CRYPTOMATOR_MOUNT_MODE="${CRYPTOMATOR_MOUNT_MODE:-auto}"

RSYNC_DELETE="${RSYNC_DELETE:-false}"
RSYNC_ARGS="${RSYNC_ARGS:--rtv --no-owner --no-group --no-perms}"
RSYNC_EXTRA_ARGS="${RSYNC_EXTRA_ARGS:-}"

MOUNT_TIMEOUT_SECONDS="${MOUNT_TIMEOUT_SECONDS:-60}"
SYNC_INTERVAL_MINUTES="${SYNC_INTERVAL_MINUTES:-0}"

CRYPTOMATOR_PID=""
WEBDAV_MOUNTED="false"

log_info() {
  printf '[%s] \033[94mINF\033[0m: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

log_warn() {
  printf '[%s] \033[93mWRN\033[0m: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

log_error() {
  printf '[%s] \033[91mERR\033[0m: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

exit_failed() {
  local exit_code="$1"
  shift

  log_error "$*"
  exit "$exit_code"
}

cleanup_resources() {
  log_info "Cleaning up..."

  if mountpoint -q "$VAULT_DECRYPTED_DIR"; then
    log_info "Unmounting decrypted vault: $VAULT_DECRYPTED_DIR"

    fusermount3 -u "$VAULT_DECRYPTED_DIR" 2>/dev/null || \
      fusermount -u "$VAULT_DECRYPTED_DIR" 2>/dev/null || \
      umount "$VAULT_DECRYPTED_DIR" 2>/dev/null || \
      umount -l "$VAULT_DECRYPTED_DIR" 2>/dev/null || \
      true
  fi

  if [[ -n "${CRYPTOMATOR_PID}" ]] && kill -0 "$CRYPTOMATOR_PID" 2>/dev/null; then
    log_info "Stopping Cryptomator CLI..."

    kill -TERM "$CRYPTOMATOR_PID" 2>/dev/null || true

    for _ in $(seq 1 5); do
      if ! kill -0 "$CRYPTOMATOR_PID" 2>/dev/null; then
        wait "$CRYPTOMATOR_PID" 2>/dev/null || true
        CRYPTOMATOR_PID=""
        log_info "Cryptomator CLI stopped."
        WEBDAV_MOUNTED="false"
        return 0
      fi
      sleep 1
    done

    log_warn "Cryptomator CLI did not stop after SIGTERM, sending SIGKILL..."
    kill -KILL "$CRYPTOMATOR_PID" 2>/dev/null || true
    wait "$CRYPTOMATOR_PID" 2>/dev/null || true
    CRYPTOMATOR_PID=""
    log_warn "Cryptomator CLI killed."
  fi

  CRYPTOMATOR_PID=""
  WEBDAV_MOUNTED="false"
}

cleanup() {
  trap - EXIT INT TERM
  cleanup_resources
}

trap cleanup EXIT
trap 'cleanup; exit "$EXIT_OK"' INT
trap 'cleanup; exit "$EXIT_OK"' TERM

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

require_dir() {
  local dir="$1"
  local name="$2"

  if [[ ! -d "$dir" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "$name does not exist: $dir"
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

wait_for_mountpoint() {
  local timeout_seconds="${1:-60}"
  local current_dev=""

  for _ in $(seq 1 "$timeout_seconds"); do
    current_dev="$(stat -c '%d' "$VAULT_DECRYPTED_DIR")"

    if [[ "$current_dev" != "$VAULT_DECRYPTED_BASE_DEV" ]]; then
      return 0
    fi

    if [[ -n "${CRYPTOMATOR_PID}" ]] && ! kill -0 "$CRYPTOMATOR_PID" 2>/dev/null; then
      return 1
    fi

    sleep 1
  done

  return 1
}

sync_once() {
  local delete_args=()

  if [[ "$RSYNC_DELETE" == "true" ]]; then
    delete_args=(--delete)
  fi

  log_info "Syncing $SYNC_DIR/ -> $VAULT_DECRYPTED_DIR/"

  set +e
  # shellcheck disable=SC2086
  rsync $RSYNC_ARGS "${delete_args[@]}" $RSYNC_EXTRA_ARGS "$SYNC_DIR"/ "$VAULT_DECRYPTED_DIR"/
  local rsync_exit_code="$?"
  set -e

  if [[ "$rsync_exit_code" -ne 0 ]]; then
    exit_failed "$EXIT_GENERAL_ERROR" "rsync failed with exit code $rsync_exit_code"
  fi

  log_info "Sync finished."
}

unlock_fuse() {
  log_info "Unlocking vault via FUSE..."

  local password_file="/tmp/cryptomator-password"
  local cryptomator_log="/tmp/cryptomator-fuse.log"

  : > "$cryptomator_log"

  umask 077
  printf '%s\n' "$VAULT_PASSWORD" > "$password_file"

  cryptomator-cli unlock \
    --password:stdin \
    --mounter=org.cryptomator.frontend.fuse.mount.LinuxFuseMountProvider \
    --mountPoint="$VAULT_DECRYPTED_DIR" \
    "$VAULT_ENCRYPTED_DIR" \
    < "$password_file" \
    > "$cryptomator_log" \
    2>&1 &

  CRYPTOMATOR_PID="$!"

  rm -f "$password_file"

  if ! wait_for_mountpoint "$MOUNT_TIMEOUT_SECONDS"; then
    log_error "FUSE unlock failed."
    cat "$cryptomator_log" >&2 || true
    return 1
  fi

  log_info "Vault unlocked via FUSE."
}

unlock_webdav() {
  log_info "Unlocking vault via WebDAV..."

  local cryptomator_log="/tmp/cryptomator-webdav.log"
  local password_file="/tmp/cryptomator-password"
  local davfs_error_log="/tmp/davfs2-mount-error.log"
  local davfs_secrets_tmp="/tmp/davfs2-secrets"
  local webdav_url=""
  # The WebDAV username and password are only used by `davfs2` to avoid interactive prompts when mounting the local WebDAV endpoint exposed by Cryptomator CLI.
  local davfs_user="cryptomator"
  local davfs_pass="cryptomator"

  : > "$cryptomator_log"
  : > "$davfs_error_log"

  umask 077
  printf '%s\n' "$VAULT_PASSWORD" > "$password_file"

  cryptomator-cli unlock \
    --password:stdin \
    --mounter=org.cryptomator.frontend.webdav.mount.FallbackMounter \
    "$VAULT_ENCRYPTED_DIR" \
    < "$password_file" \
    > "$cryptomator_log" \
    2>&1 &

  CRYPTOMATOR_PID="$!"

  rm -f "$password_file"

  log_info "Waiting for Cryptomator WebDAV URL..."

  for _ in $(seq 1 "$MOUNT_TIMEOUT_SECONDS"); do
    webdav_url="$(
      sed -n 's/.*Unlocked and mounted vault successfully to \(http:\/\/[^[:space:]]*\).*/\1/p' "$cryptomator_log" | tail -n1
    )"

    if [[ -n "$webdav_url" ]]; then
      log_info "Detected WebDAV endpoint: $webdav_url"
      break
    fi

    if [[ -n "${CRYPTOMATOR_PID}" ]] && ! kill -0 "$CRYPTOMATOR_PID" 2>/dev/null; then
      log_error "Cryptomator CLI exited before WebDAV URL could be detected."
      cat "$cryptomator_log" >&2 || true
      return 1
    fi

    sleep 1
  done

  if [[ -z "$webdav_url" ]]; then
    log_error "WebDAV URL could not be detected."
    cat "$cryptomator_log" >&2 || true
    return 1
  fi

  log_info "Preparing davfs2 credentials..."

  mkdir -p /etc/davfs2
  touch /etc/davfs2/secrets
  chmod 600 /etc/davfs2/secrets

  grep -vF "$webdav_url" /etc/davfs2/secrets > "$davfs_secrets_tmp" || true
  mv "$davfs_secrets_tmp" /etc/davfs2/secrets

  printf '%s %s %s\n' "$webdav_url" "$davfs_user" "$davfs_pass" >> /etc/davfs2/secrets
  chmod 600 /etc/davfs2/secrets

  log_info "Mounting WebDAV endpoint to $VAULT_DECRYPTED_DIR"

  for _ in $(seq 1 "$MOUNT_TIMEOUT_SECONDS"); do
    : > "$davfs_error_log"

    if mount -t davfs \
      -o uid="$(id -u)",gid="$(id -g)",rw,nouser \
      "$webdav_url" \
      "$VAULT_DECRYPTED_DIR" \
      2>"$davfs_error_log"; then
      WEBDAV_MOUNTED="true"
      log_info "Vault unlocked via WebDAV and mounted to $VAULT_DECRYPTED_DIR."
      return 0
    fi

    sleep 1
  done

  log_error "WebDAV mount failed."
  cat "$davfs_error_log" >&2 || true
  return 1
}

validate_config() {
  require_dir "$SYNC_DIR" "sync dir"
  require_dir "$VAULT_ENCRYPTED_DIR" "encrypted vault dir"
  require_cryptomator_vault "$VAULT_ENCRYPTED_DIR"
  require_empty_mountpoint

  if [[ -z "${CRYPTOMATOR_VAULT_PASSWORD:-}" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "CRYPTOMATOR_VAULT_PASSWORD is required"
  fi

  case "$CRYPTOMATOR_MOUNT_MODE" in
    fuse|webdav|auto)
      ;;
    *)
      exit_failed "$EXIT_CONFIG_ERROR" "invalid CRYPTOMATOR_MOUNT_MODE: $CRYPTOMATOR_MOUNT_MODE. Allowed values: fuse, webdav, auto"
      ;;
  esac

  if [[ "$RSYNC_DELETE" != "true" && "$RSYNC_DELETE" != "false" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "RSYNC_DELETE must be true or false"
  fi

  if ! [[ "$SYNC_INTERVAL_MINUTES" =~ ^[0-9]+$ ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "SYNC_INTERVAL_MINUTES must be a non-negative integer"
  fi

  if ! [[ "$MOUNT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$MOUNT_TIMEOUT_SECONDS" == "0" ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "MOUNT_TIMEOUT_SECONDS must be a positive integer"
  fi
}

load_password() {
  VAULT_PASSWORD="$CRYPTOMATOR_VAULT_PASSWORD"
  unset CRYPTOMATOR_VAULT_PASSWORD
}

mount_vault() {
  case "$CRYPTOMATOR_MOUNT_MODE" in
    fuse)
      unlock_fuse || exit_failed "$EXIT_GENERAL_ERROR" "failed to mount vault using FUSE"
      ;;
    webdav)
      unlock_webdav || exit_failed "$EXIT_GENERAL_ERROR" "failed to mount vault using WebDAV"
      ;;
    auto)
      if ! unlock_fuse; then
        log_warn "FUSE mount failed, trying WebDAV fallback..."
        cleanup_resources
        require_empty_mountpoint
        unlock_webdav || exit_failed "$EXIT_GENERAL_ERROR" "failed to mount vault using FUSE and WebDAV fallback"
      fi
      ;;
  esac
}

run_sync() {
  if [[ "$SYNC_INTERVAL_MINUTES" == "0" ]]; then
    sync_once
    log_info "One-shot sync finished."
    return 0
  fi

  log_info "Continuous sync enabled. Interval: ${SYNC_INTERVAL_MINUTES} minute(s)"

  while true; do
    sync_once
    sleep "$((SYNC_INTERVAL_MINUTES * 60))"
  done
}

main() {
  validate_config
  load_password
  mount_vault
  run_sync
}

main "$@"