#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
. /common.sh
# shellcheck disable=SC1091
. /config.sh

load_config_defaults

CRYPTOMATOR_PID=""
ACTIVE_MOUNT_MODE=""
SYNC_LOCK_FILE="/tmp/cryptomator-vault-sync.lock"
SYNC_USER_CONTEXT_READY="${SYNC_USER_CONTEXT_READY:-false}"

acquire_sync_lock() {
  exec 9>"$SYNC_LOCK_FILE"

  if ! flock -n 9; then
    log_warn "Previous sync cycle is still running. Skipping this sync cycle."
    exit "$EXIT_OK"
  fi
}

cleanup_resources() {
  log_info "Cleaning up..."

  if mountpoint -q "$VAULT_DECRYPTED_DIR"; then
    log_info "Unmounting Cryptomator vault: $VAULT_DECRYPTED_DIR"

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
}

cleanup() {
  trap - EXIT INT TERM
  cleanup_resources

  if [[ "$EXIT_IS_FAILURE" != "true" && -z "$SYNC_CRON" ]]; then
    write_status "current-status" "stopped"
  fi
}

trap cleanup EXIT
trap 'cleanup; exit "$EXIT_OK"' INT
trap 'cleanup; exit "$EXIT_OK"' TERM

ensure_runtime_user_exists() {
  local user_name="syncuser"
  local group_name="syncgroup"

  if ! getent group "$PGID" >/dev/null 2>&1; then
    log_info "Creating runtime group ${group_name} with GID ${PGID}"
    groupadd --gid "$PGID" "$group_name"
  else
    group_name="$(getent group "$PGID" | cut -d: -f1)"
  fi

  if ! getent passwd "$PUID" >/dev/null 2>&1; then
    log_info "Creating runtime user ${user_name} with UID ${PUID} and GID ${PGID}"
    useradd \
      --uid "$PUID" \
      --gid "$PGID" \
      --home-dir /tmp/cryptomator-vault-sync-home \
      --shell /usr/sbin/nologin \
      "$user_name"
  fi
}

prepare_runtime_user_context() {
  log_info "Preparing sync runtime user: ${PUID}:${PGID}"

  ensure_runtime_user_exists

  mkdir -p "$VAULT_DECRYPTED_DIR" "$STATE_DIR" /tmp/cryptomator-vault-sync-home

  chown "$PUID:$PGID" "$VAULT_DECRYPTED_DIR" 2>/dev/null || true
  chown "$PUID:$PGID" "$STATE_DIR" 2>/dev/null || true
  chown "$PUID:$PGID" "$STATE_DIR"/* 2>/dev/null || true
  chown "$PUID:$PGID" /tmp/cryptomator-vault-sync-home 2>/dev/null || true

  chmod 700 /tmp/cryptomator-vault-sync-home 2>/dev/null || true
}

switch_to_runtime_user_if_needed() {
  if [[ "$SYNC_USER_CONTEXT_READY" == "true" ]]; then
    umask "$UMASK"
    return 0
  fi

  if [[ "$(id -u)" != "0" ]]; then
    log_info "Sync process is already running as $(id -u):$(id -g)."
    export SYNC_USER_CONTEXT_READY=true
    umask "$UMASK"
    return 0
  fi

  if [[ "$PUID" == "0" && "$PGID" == "0" ]]; then
    log_info "Sync process will run as root because PUID=0 and PGID=0."
    export SYNC_USER_CONTEXT_READY=true
    umask "$UMASK"
    return 0
  fi

  prepare_runtime_user_context

  log_info "Restarting sync process as ${PUID}:${PGID} with umask ${UMASK}"

  export SYNC_USER_CONTEXT_READY=true
  export HOME=/tmp/cryptomator-vault-sync-home

  exec setpriv \
    --reuid "$PUID" \
    --regid "$PGID" \
    --clear-groups \
    -- "$0" "$@"
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
  local dry_run_args=()
  local exclude_args=()
  local delete_args=()
  local inplace_args=()

  if [[ "$DRY_RUN" == "true" ]]; then
    dry_run_args=(--dry-run)
    log_warn "DRY_RUN enabled. No files will be written to the vault."
  fi

  if [[ "$RSYNC_INPLACE" == "true" ]] || [[ "$RSYNC_INPLACE" == "auto" && "$ACTIVE_MOUNT_MODE" == "webdav" ]]; then
    inplace_args=(--inplace)
  fi

  if [[ -n "${RSYNC_EXCLUDE_FILE:-}" ]]; then
    exclude_args=(--exclude-from "$RSYNC_EXCLUDE_FILE")
  fi

  if [[ "$RSYNC_DELETE" == "true" ]]; then
    delete_args=(--delete)
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Running rsync dry-run syncing $SYNC_DIR/ -> $VAULT_DECRYPTED_DIR/"
  else
    log_info "Running rsync syncing $SYNC_DIR/ -> $VAULT_DECRYPTED_DIR/"
  fi

  log_info "Rsync args: $RSYNC_ARGS ${dry_run_args[*]} ${delete_args[*]} ${exclude_args[*]} ${inplace_args[*]} $RSYNC_EXTRA_ARGS"

  set +e
  # shellcheck disable=SC2086
  rsync $RSYNC_ARGS "${dry_run_args[@]}" "${delete_args[@]}" "${exclude_args[@]}" "${inplace_args[@]}" $RSYNC_EXTRA_ARGS "$SYNC_DIR"/ "$VAULT_DECRYPTED_DIR"/
  local rsync_exit_code="$?"
  set -e

  if [[ "$rsync_exit_code" -ne 0 ]]; then
    exit_failed "$EXIT_GENERAL_ERROR" "Rsync failed with exit code $rsync_exit_code"
  fi

  log_info "Rsync finished."
}

unlock_fuse() {
  log_info "Unlocking Cryptomator vault via FUSE..."

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

  if ! ls -la "$VAULT_DECRYPTED_DIR" >/dev/null 2>&1; then
    log_warn "FUSE mount is not accessible. Falling back may be required."
    return 1
  fi

  ACTIVE_MOUNT_MODE="fuse"
  log_info "Vault unlocked via FUSE."
}

unlock_webdav() {
  log_info "Unlocking Cryptomator vault via WebDAV..."

  local cryptomator_log="/tmp/cryptomator-webdav.log"
  local password_file="/tmp/cryptomator-password"
  local davfs_error_log="/tmp/davfs2-mount-error.log"
  local davfs_secrets_tmp="/tmp/davfs2-secrets"
  local davfs_user="cryptomator"
  local davfs_pass="cryptomator"

  local webdav_host="127.0.0.1"
  local webdav_port="59317"
  local webdav_volume_id="vault"
  local webdav_url="http://${webdav_host}:${webdav_port}/${webdav_volume_id}/"

  : > "$cryptomator_log"
  : > "$davfs_error_log"

  umask 077
  printf '%s\n' "$VAULT_PASSWORD" > "$password_file"

  cryptomator-cli unlock \
    --password:stdin \
    --mounter=org.cryptomator.frontend.webdav.mount.FallbackMounter \
    --volumeId="$webdav_volume_id" \
    --loopbackPort="$webdav_port" \
    "$VAULT_ENCRYPTED_DIR" \
    < "$password_file" \
    > "$cryptomator_log" \
    2>&1 &

  CRYPTOMATOR_PID="$!"

  rm -f "$password_file"

  log_info "Waiting for Cryptomator WebDAV endpoint: $webdav_url"

  local endpoint_available="false"

  for _ in $(seq 1 "$MOUNT_TIMEOUT_SECONDS"); do
    if curl --silent --fail --show-error --max-time 1 "$webdav_url" >/dev/null 2>&1; then
      endpoint_available="true"
      log_info "Cryptomator WebDAV endpoint is available."
      break
    fi

    if [[ -n "${CRYPTOMATOR_PID}" ]] && ! kill -0 "$CRYPTOMATOR_PID" 2>/dev/null; then
      log_error "Cryptomator CLI exited before WebDAV endpoint became available."
      cat "$cryptomator_log" >&2 || true
      return 1
    fi

    sleep 1
  done

  if [[ "$endpoint_available" != "true" ]]; then
    log_error "Cryptomator WebDAV endpoint did not become available in time."
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
      ACTIVE_MOUNT_MODE="webdav"
      log_info "Vault unlocked via WebDAV and mounted to $VAULT_DECRYPTED_DIR."
      return 0
    fi

    sleep 1
  done

  log_error "WebDAV mount failed."
  cat "$davfs_error_log" >&2 || true
  return 1
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

prepare_vault_for_rclone() {
  if [[ "$UPSTREAM_ENABLED" != "true" ]] || [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  log_info "Preparing Cryptomator vault for rclone..."

  sync -f "$VAULT_ENCRYPTED_DIR" 2>/dev/null || sync

  if [[ "$UPSTREAM_START_DELAY_SECONDS" != "0" ]]; then
    log_info "Waiting ${UPSTREAM_START_DELAY_SECONDS}s before running rclone..."
    sleep "$UPSTREAM_START_DELAY_SECONDS"
  fi
}

handle_upstream_error() {
  local message="$1"

  write_status "last-error" "$message"
  write_status "current-status" "upstream-error"

  if [[ -n "$SYNC_CRON" && "$UPSTREAM_FAIL_ACTION" == "continue" ]]; then
    log_error "$message"
    log_warn "Continuing despite upstream error. Next scheduled cycle will retry."
    return 0
  fi

  exit_failed "$EXIT_GENERAL_ERROR" "$message"
}

run_rclone_check() {
  local destination="$1"
  local rclone_check_exit_code=0

  if [[ "$UPSTREAM_CHECK" != "true" ]]; then
    return 0
  fi

  log_info "Running rclone check $VAULT_ENCRYPTED_DIR -> $destination"
  log_info "Rclone check args: check $VAULT_ENCRYPTED_DIR $destination --config $UPSTREAM_CONFIG $UPSTREAM_EXTRA_ARGS"

  set +e
  # shellcheck disable=SC2086
  rclone check "$VAULT_ENCRYPTED_DIR" "$destination" \
    --config "$UPSTREAM_CONFIG" \
    $UPSTREAM_EXTRA_ARGS
  rclone_check_exit_code="$?"
  set -e

  if [[ "$rclone_check_exit_code" -ne 0 ]]; then
    handle_upstream_error "Rclone check failed for destination '$destination' with exit code $rclone_check_exit_code"
    return 1
  fi

  log_info "Rclone check finished for destination: $destination"
}

run_rclone() {
  if [[ "$UPSTREAM_ENABLED" != "true" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "Skipping upstream sync because DRY_RUN=true."
    return 0
  fi

  local destination=""
  local rclone_exit_code=0
  local destination_count=0
  local destinations=()

  IFS='|' read -r -a destinations <<< "$UPSTREAM_DESTINATIONS"

  for destination in "${destinations[@]}"; do
    destination="$(trim "$destination")"

    if [[ -z "$destination" ]]; then
      continue
    fi

    destination_count="$((destination_count + 1))"

    log_info "Running rclone $UPSTREAM_MODE $VAULT_ENCRYPTED_DIR -> $destination"
    log_info "Rclone args: $UPSTREAM_MODE $VAULT_ENCRYPTED_DIR $destination --config $UPSTREAM_CONFIG $UPSTREAM_EXTRA_ARGS"

    set +e
    # shellcheck disable=SC2086
    rclone "$UPSTREAM_MODE" "$VAULT_ENCRYPTED_DIR" "$destination" \
      --config "$UPSTREAM_CONFIG" \
      $UPSTREAM_EXTRA_ARGS
    rclone_exit_code="$?"
    set -e

    if [[ "$rclone_exit_code" -ne 0 ]]; then
      handle_upstream_error "Rclone failed for destination '$destination' with exit code $rclone_exit_code"
      return 1
    fi

    log_info "Rclone finished for destination: $destination"
    
    if ! run_rclone_check "$destination"; then
      return 1
    fi
  done

  if [[ "$destination_count" -eq 0 ]]; then
    exit_failed "$EXIT_CONFIG_ERROR" "UPSTREAM_DESTINATIONS does not contain any valid destination"
  fi

  log_info "Rclone finished for all destinations."
}

sync_cycle() {
  write_status "current-status" "running"

  mount_vault
  sync_once
  cleanup_resources
  prepare_vault_for_rclone

  if ! run_rclone; then
    write_status "last-error" "sync cycle finished with upstream error"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY_RUN finished successfully. last-success was not updated."
  else
    write_status "last-success"
  fi

  write_status "current-status" "idle"
}

main() {
  switch_to_runtime_user_if_needed "$@"
  acquire_sync_lock
  validate_config
  validate_sync_runtime
  load_password
  sync_cycle
}

main "$@"
