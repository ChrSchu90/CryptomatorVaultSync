#!/usr/bin/env bash
set -Eeuo pipefail

SYNC_DIR="${SYNC_DIR:-/sync}"
VAULT_ENCRYPTED_DIR="${VAULT_ENCRYPTED_DIR:-/vault-encrypted}"
VAULT_DECRYPTED_DIR="${VAULT_DECRYPTED_DIR:-/vault-decrypted}"

CRYPTOMATOR_MOUNT_MODE="${CRYPTOMATOR_MOUNT_MODE:-fuse}"
CRYPTOMATOR_WEBDAV_URL="${CRYPTOMATOR_WEBDAV_URL:-http://localhost:8080/vault/}"

RSYNC_DELETE="${RSYNC_DELETE:-false}"
RSYNC_EXTRA_ARGS="${RSYNC_EXTRA_ARGS:-}"

: "${CRYPTOMATOR_VAULT_PASSWORD:?CRYPTOMATOR_VAULT_PASSWORD is required}"

CRYPTOMATOR_PID=""
WEBDAV_MOUNTED="false"

log() {
  printf '[CryptomatorVaultSync] %s\n' "$*"
}

cleanup() {
  log "Cleaning up..."

  if mountpoint -q "$VAULT_DECRYPTED_DIR"; then
    log "Unmounting decrypted vault: $VAULT_DECRYPTED_DIR"
    umount "$VAULT_DECRYPTED_DIR" 2>/dev/null || \
      fusermount3 -u "$VAULT_DECRYPTED_DIR" 2>/dev/null || \
      true
  fi

  if [[ -n "${CRYPTOMATOR_PID}" ]] && kill -0 "$CRYPTOMATOR_PID" 2>/dev/null; then
    log "Stopping Cryptomator CLI..."
    kill -INT "$CRYPTOMATOR_PID" 2>/dev/null || true
    wait "$CRYPTOMATOR_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT INT TERM

require_dir() {
  local dir="$1"
  local name="$2"

  if [[ ! -d "$dir" ]]; then
    log "ERROR: $name does not exist: $dir"
    exit 1
  fi
}

require_empty_mountpoint() {
  mkdir -p "$VAULT_DECRYPTED_DIR"

  if mountpoint -q "$VAULT_DECRYPTED_DIR"; then
    log "ERROR: already mounted: $VAULT_DECRYPTED_DIR"
    exit 1
  fi

  if find "$VAULT_DECRYPTED_DIR" -mindepth 1 -maxdepth 1 | read -r; then
    log "ERROR: vault decrypted dir must be empty: $VAULT_DECRYPTED_DIR"
    exit 1
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

  VAULT_PASSWORD="$CRYPTOMATOR_VAULT_PASSWORD"
  unset CRYPTOMATOR_VAULT_PASSWORD

  printf '%s' "$VAULT_PASSWORD" | cryptomator-cli unlock \
    --password:stdin \
    --mounter=org.cryptomator.frontend.fuse.mount.LinuxFuseMountProvider \
    --mountPoint="$VAULT_DECRYPTED_DIR" \
    "$VAULT_ENCRYPTED_DIR" &

  CRYPTOMATOR_PID="$!"

  if ! wait_for_mountpoint 60; then
    log "FUSE unlock failed."
    return 1
  fi

  log "Vault unlocked via FUSE."
}

unlock_webdav() {
  log "Unlocking vault via WebDAV fallback..."

  VAULT_PASSWORD="$CRYPTOMATOR_VAULT_PASSWORD"
  unset CRYPTOMATOR_VAULT_PASSWORD

  printf '%s' "$VAULT_PASSWORD" | cryptomator-cli unlock \
    --password:stdin \
    --mounter=org.cryptomator.frontend.webdav.mount.FallbackMounter \
    "$VAULT_ENCRYPTED_DIR" &

  CRYPTOMATOR_PID="$!"

  log "Waiting for WebDAV endpoint: $CRYPTOMATOR_WEBDAV_URL"

  for _ in $(seq 1 60); do
    if mount -t davfs \
      -o username=,uid="$(id -u)",gid="$(id -g)",rw \
      "$CRYPTOMATOR_WEBDAV_URL" \
      "$VAULT_DECRYPTED_DIR" 2>/dev/null; then
      WEBDAV_MOUNTED="true"
      log "Vault unlocked via WebDAV and mounted to $VAULT_DECRYPTED_DIR."
      return 0
    fi

    if ! kill -0 "$CRYPTOMATOR_PID" 2>/dev/null; then
      log "Cryptomator CLI exited before WebDAV could be mounted."
      return 1
    fi

    sleep 1
  done

  log "WebDAV mount failed."
  return 1
}

main() {
  require_dir "$SYNC_DIR" "sync dir"
  require_dir "$VAULT_ENCRYPTED_DIR" "encrypted vault dir"
  require_empty_mountpoint

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
    *)
      log "ERROR: invalid CRYPTOMATOR_MOUNT_MODE: $CRYPTOMATOR_MOUNT_MODE"
      log "Allowed values: fuse, webdav, auto"
      exit 1
      ;;
  esac

  sync_once
}

main "$@"