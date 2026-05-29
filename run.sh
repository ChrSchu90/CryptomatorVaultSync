#!/usr/bin/env bash
set -Eeuo pipefail

SYNC_DIR="${SYNC_DIR:-/sync}"
VAULT_ENCRYPTED_DIR="${VAULT_ENCRYPTED_DIR:-/vault-encrypted}"
VAULT_DECRYPTED_DIR="${VAULT_DECRYPTED_DIR:-/vault-decrypted}"
VAULT_DECRYPTED_BASE_DEV=""

CRYPTOMATOR_MOUNT_MODE="${CRYPTOMATOR_MOUNT_MODE:-auto}"

RSYNC_DELETE="${RSYNC_DELETE:-false}"
RSYNC_ARGS="${RSYNC_ARGS:--rtv --no-owner --no-group --no-perms}"
RSYNC_EXTRA_ARGS="${RSYNC_EXTRA_ARGS:-}"

MOUNT_TIMEOUT_SECONDS="${MOUNT_TIMEOUT_SECONDS:-60}"
SYNC_INTERVAL_MINUTES="${SYNC_INTERVAL_MINUTES:-0}"

: "${CRYPTOMATOR_VAULT_PASSWORD:?CRYPTOMATOR_VAULT_PASSWORD is required}"

VAULT_PASSWORD="$CRYPTOMATOR_VAULT_PASSWORD"
unset CRYPTOMATOR_VAULT_PASSWORD

CRYPTOMATOR_PID=""
WEBDAV_MOUNTED="false"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

cleanup() {
  log "Cleaning up..."

  trap - EXIT INT TERM

  if mountpoint -q "$VAULT_DECRYPTED_DIR"; then
    log "Unmounting decrypted vault: $VAULT_DECRYPTED_DIR"

    fusermount3 -u "$VAULT_DECRYPTED_DIR" 2>/dev/null || \
      fusermount -u "$VAULT_DECRYPTED_DIR" 2>/dev/null || \
      umount "$VAULT_DECRYPTED_DIR" 2>/dev/null || \
      umount -l "$VAULT_DECRYPTED_DIR" 2>/dev/null || \
      true
  fi

  if [[ -n "${CRYPTOMATOR_PID}" ]] && kill -0 "$CRYPTOMATOR_PID" 2>/dev/null; then
    log "Stopping Cryptomator CLI..."

    kill -TERM "$CRYPTOMATOR_PID" 2>/dev/null || true

    for _ in $(seq 1 5); do
      if ! kill -0 "$CRYPTOMATOR_PID" 2>/dev/null; then
        wait "$CRYPTOMATOR_PID" 2>/dev/null || true
        CRYPTOMATOR_PID=""
        log "Cryptomator CLI stopped."
        WEBDAV_MOUNTED="false"
        return 0
      fi
      sleep 1
    done

    log "Cryptomator CLI did not stop after SIGTERM, sending SIGKILL..."
    kill -KILL "$CRYPTOMATOR_PID" 2>/dev/null || true
    wait "$CRYPTOMATOR_PID" 2>/dev/null || true
    CRYPTOMATOR_PID=""
    log "Cryptomator CLI killed."
  fi

  CRYPTOMATOR_PID=""
  WEBDAV_MOUNTED="false"
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

require_dir() {
  local dir="$1"
  local name="$2"

  if [[ ! -d "$dir" ]]; then
    fail "$name does not exist: $dir"
  fi
}

require_empty_mountpoint() {
  mkdir -p "$VAULT_DECRYPTED_DIR"

  if find "$VAULT_DECRYPTED_DIR" -mindepth 1 -maxdepth 1 | read -r; then
    fail "vault decrypted dir must be empty: $VAULT_DECRYPTED_DIR"
  fi

  VAULT_DECRYPTED_BASE_DEV="$(stat -c '%d' "$VAULT_DECRYPTED_DIR")"
  log "Base device for decrypted vault dir: $VAULT_DECRYPTED_BASE_DEV"
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

  log "Syncing $SYNC_DIR/ -> $VAULT_DECRYPTED_DIR/"

  # shellcheck disable=SC2086
  rsync $RSYNC_ARGS "${delete_args[@]}" $RSYNC_EXTRA_ARGS "$SYNC_DIR"/ "$VAULT_DECRYPTED_DIR"/

  log "Sync finished."
}

unlock_fuse() {
  log "Unlocking vault via FUSE..."

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
    log "FUSE unlock failed."
    cat "$cryptomator_log" >&2 || true
    return 1
  fi

  log "Vault unlocked via FUSE."
}

unlock_webdav() {
  log "Unlocking vault via WebDAV..."

  local cryptomator_log="/tmp/cryptomator-webdav.log"
  local password_file="/tmp/cryptomator-password"
  local davfs_error_log="/tmp/davfs2-mount-error.log"
  local davfs_secrets_tmp="/tmp/davfs2-secrets"
  local webdav_url=""
  local davfs_user="${CRYPTOMATOR_WEBDAV_USERNAME:-cryptomator}"
  local davfs_pass="${CRYPTOMATOR_WEBDAV_PASSWORD:-cryptomator}"

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

  log "Waiting for Cryptomator WebDAV URL..."

  for _ in $(seq 1 "$MOUNT_TIMEOUT_SECONDS"); do
    webdav_url="$(
      sed -n 's/.*Unlocked and mounted vault successfully to \(http:\/\/[^[:space:]]*\).*/\1/p' "$cryptomator_log" | tail -n1
    )"

    if [[ -n "$webdav_url" ]]; then
      log "Detected WebDAV endpoint: $webdav_url"
      break
    fi

    if [[ -n "${CRYPTOMATOR_PID}" ]] && ! kill -0 "$CRYPTOMATOR_PID" 2>/dev/null; then
      log "Cryptomator CLI exited before WebDAV URL could be detected."
      cat "$cryptomator_log" >&2 || true
      return 1
    fi

    sleep 1
  done

  if [[ -z "$webdav_url" ]]; then
    log "WebDAV URL could not be detected."
    cat "$cryptomator_log" >&2 || true
    return 1
  fi

  log "Preparing davfs2 credentials..."

  mkdir -p /etc/davfs2
  touch /etc/davfs2/secrets
  chmod 600 /etc/davfs2/secrets

  grep -vF "$webdav_url" /etc/davfs2/secrets > "$davfs_secrets_tmp" || true
  mv "$davfs_secrets_tmp" /etc/davfs2/secrets

  printf '%s %s %s\n' "$webdav_url" "$davfs_user" "$davfs_pass" >> /etc/davfs2/secrets
  chmod 600 /etc/davfs2/secrets

  log "Mounting WebDAV endpoint to $VAULT_DECRYPTED_DIR"

  for _ in $(seq 1 "$MOUNT_TIMEOUT_SECONDS"); do
    : > "$davfs_error_log"

    if mount -t davfs \
      -o uid="$(id -u)",gid="$(id -g)",rw,nouser \
      "$webdav_url" \
      "$VAULT_DECRYPTED_DIR" \
      2>"$davfs_error_log"; then
      WEBDAV_MOUNTED="true"
      log "Vault unlocked via WebDAV and mounted to $VAULT_DECRYPTED_DIR."
      return 0
    fi

    sleep 1
  done

  log "WebDAV mount failed."
  cat "$davfs_error_log" >&2 || true
  return 1
}

validate_config() {
  require_dir "$SYNC_DIR" "sync dir"
  require_dir "$VAULT_ENCRYPTED_DIR" "encrypted vault dir"
  require_empty_mountpoint

  case "$CRYPTOMATOR_MOUNT_MODE" in
    fuse|webdav|auto)
      ;;
    *)
      fail "invalid CRYPTOMATOR_MOUNT_MODE: $CRYPTOMATOR_MOUNT_MODE. Allowed values: fuse, webdav, auto"
      ;;
  esac

  if [[ "$RSYNC_DELETE" != "true" && "$RSYNC_DELETE" != "false" ]]; then
    fail "RSYNC_DELETE must be true or false"
  fi

  if ! [[ "$SYNC_INTERVAL_MINUTES" =~ ^[0-9]+$ ]]; then
    fail "SYNC_INTERVAL_MINUTES must be a non-negative integer"
  fi
}

mount_vault() {
  case "$CRYPTOMATOR_MOUNT_MODE" in
    fuse)
      unlock_fuse
      ;;
    webdav)
      unlock_webdav
      ;;
    auto)
      if ! unlock_fuse; then
        cleanup
        require_empty_mountpoint
        unlock_webdav
      fi
      ;;
  esac
}

run_sync() {
  if [[ "$SYNC_INTERVAL_MINUTES" == "0" ]]; then
    sync_once
    log "One-shot sync finished."
    return 0
  fi

  log "Continuous sync enabled. Interval: ${SYNC_INTERVAL_MINUTES} minute(s)"

  while true; do
    sync_once
    sleep "$((SYNC_INTERVAL_MINUTES * 60))"
  done
}

main() {
  validate_config
  mount_vault
  run_sync
}

main "$@"