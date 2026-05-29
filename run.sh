#!/usr/bin/env bash
set -Eeuo pipefail

SYNC_DIR="${SYNC_DIR:-/sync}"
VAULT_ENCRYPTED_DIR="${VAULT_ENCRYPTED_DIR:-/vault-encrypted}"
VAULT_DECRYPTED_DIR="${VAULT_DECRYPTED_DIR:-/vault-decrypted}"

CRYPTOMATOR_MOUNT_MODE="${CRYPTOMATOR_MOUNT_MODE:-fuse}"
CRYPTOMATOR_WEBDAV_URL="${CRYPTOMATOR_WEBDAV_URL:-}"

RSYNC_DELETE="${RSYNC_DELETE:-false}"
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

  if mountpoint -q "$VAULT_DECRYPTED_DIR"; then
    log "Unmounting decrypted vault: $VAULT_DECRYPTED_DIR"

    if [[ "$WEBDAV_MOUNTED" == "true" ]]; then
      umount "$VAULT_DECRYPTED_DIR" 2>/dev/null || true
    else
      fusermount3 -u "$VAULT_DECRYPTED_DIR" 2>/dev/null || \
        fusermount -u "$VAULT_DECRYPTED_DIR" 2>/dev/null || \
        umount "$VAULT_DECRYPTED_DIR" 2>/dev/null || \
        true
    fi
  fi

  if [[ -n "${CRYPTOMATOR_PID}" ]] && kill -0 "$CRYPTOMATOR_PID" 2>/dev/null; then
    log "Stopping Cryptomator CLI..."
    kill -INT "$CRYPTOMATOR_PID" 2>/dev/null || true
    wait "$CRYPTOMATOR_PID" 2>/dev/null || true
  fi

  CRYPTOMATOR_PID=""
  WEBDAV_MOUNTED="false"
}

trap cleanup EXIT INT TERM

require_dir() {
  local dir="$1"
  local name="$2"

  if [[ ! -d "$dir" ]]; then
    fail "$name does not exist: $dir"
  fi
}

require_empty_mountpoint() {
  mkdir -p "$VAULT_DECRYPTED_DIR"

  if mountpoint -q "$VAULT_DECRYPTED_DIR"; then
    fail "already mounted: $VAULT_DECRYPTED_DIR"
  fi

  if find "$VAULT_DECRYPTED_DIR" -mindepth 1 -maxdepth 1 | read -r; then
    fail "vault decrypted dir must be empty: $VAULT_DECRYPTED_DIR"
  fi
}

wait_for_mountpoint() {
  local timeout_seconds="${1:-60}"

  for _ in $(seq 1 "$timeout_seconds"); do
    if mountpoint -q "$VAULT_DECRYPTED_DIR"; then
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
  rsync -av "${delete_args[@]}" $RSYNC_EXTRA_ARGS "$SYNC_DIR"/ "$VAULT_DECRYPTED_DIR"/

  log "Sync finished."
}

unlock_fuse() {
  log "Unlocking vault via FUSE..."

  printf '%s' "$VAULT_PASSWORD" | cryptomator-cli unlock \
    --password:stdin \
    --mounter=org.cryptomator.frontend.fuse.mount.LinuxFuseMountProvider \
    --mountPoint="$VAULT_DECRYPTED_DIR" \
    "$VAULT_ENCRYPTED_DIR" &

  CRYPTOMATOR_PID="$!"

  if ! wait_for_mountpoint "$MOUNT_TIMEOUT_SECONDS"; then
    log "FUSE unlock failed."
    return 1
  fi

  log "Vault unlocked via FUSE."
}

unlock_webdav() {
  log "Unlocking vault via WebDAV fallback..."

  : "${CRYPTOMATOR_WEBDAV_URL:?CRYPTOMATOR_WEBDAV_URL is required for WebDAV mode}"

  printf '%s' "$VAULT_PASSWORD" | cryptomator-cli unlock \
    --password:stdin \
    --mounter=org.cryptomator.frontend.webdav.mount.FallbackMounter \
    "$VAULT_ENCRYPTED_DIR" &

  CRYPTOMATOR_PID="$!"

  log "Waiting for WebDAV endpoint: $CRYPTOMATOR_WEBDAV_URL"

  for _ in $(seq 1 "$MOUNT_TIMEOUT_SECONDS"); do
    if mount -t davfs \
      -o username=,uid="$(id -u)",gid="$(id -g)",rw \
      "$CRYPTOMATOR_WEBDAV_URL" \
      "$VAULT_DECRYPTED_DIR" 2>/dev/null; then
      WEBDAV_MOUNTED="true"
      log "Vault unlocked via WebDAV and mounted to $VAULT_DECRYPTED_DIR."
      return 0
    fi

    if [[ -n "${CRYPTOMATOR_PID}" ]] && ! kill -0 "$CRYPTOMATOR_PID" 2>/dev/null; then
      log "Cryptomator CLI exited before WebDAV could be mounted."
      return 1
    fi

    sleep 1
  done

  log "WebDAV mount failed."
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

  if [[ "$CRYPTOMATOR_MOUNT_MODE" == "webdav" && -z "$CRYPTOMATOR_WEBDAV_URL" ]]; then
    fail "CRYPTOMATOR_WEBDAV_URL is required when CRYPTOMATOR_MOUNT_MODE=webdav"
  fi

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