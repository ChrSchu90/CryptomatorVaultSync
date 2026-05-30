#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")" || exit 1

IMAGE_NAME="cryptomator-vault-sync:test"
VAULT_PASSWORD=cryptomator-vault-sync

log() {
  printf '\033[92m[%s] %s\033[0m\n' "$(date '+%H:%M:%S')" "$*"
}

log_err() {
  printf '\033[91m[%s] %s\033[0m\n' "$(date '+%H:%M:%S')" "$*"
}

exit_failed() {
  log_err "$*"
  exit 1
}

cleanup() {
  rm -rf ./tests/rclone-remote ./tests/sync ./tests/tmp-vault
  docker image rm "$IMAGE_NAME" >/dev/null 2>&1 || true
}

create_temp_vault() {
  rm -rf ./tests/tmp-vault
  cp -r ./tests/test-vault ./tests/tmp-vault
}

create_sync_dir() {
  rm -rf ./tests/sync
  mkdir -p ./tests/sync
}

create_rclone_dir() {
  rm -rf ./tests/rclone-remote
  mkdir -p ./tests/rclone-remote ./tests/rclone-remote/temp-vault
}

trap cleanup EXIT

docker_cleanup() {
  create_sync_dir
  create_temp_vault
  create_rclone_dir
}

fix_test_file_permissions() {
  docker run --rm \
    -v "./tests:/tests" \
    "$IMAGE_NAME" \
    sh -c 'chmod -R a+rwX /tests/rclone-remote /tests/sync /tests/tmp-vault 2>/dev/null || true' \
    >/dev/null 2>&1 || true
}

docker_run_without_cleanup() {
  local exit_code=0
  set +e
  docker run --rm \
    -v "./tests/sync:/sync:ro" \
    -v "./tests/tmp-vault:/vault-encrypted" \
    -v "./tests/rclone:/rclone" \
    -v "./tests/rclone-remote:/rclone-remote" \
    --cap-add SYS_ADMIN \
    --device /dev/fuse:/dev/fuse \
    --security-opt apparmor:unconfined \
    -e SYNC_INTERVAL_MINUTES=0 \
    "$@" \
    "$IMAGE_NAME"
  exit_code="$?"
  set -e

  fix_test_file_permissions
  return "$exit_code"
}

docker_run() {
  docker_cleanup
  docker_run_without_cleanup
}

log "Preparing test directories and files..."
docker_cleanup

log "TEST: run.sh syntax check"
bash -n run.sh

log "TEST: healthcheck.sh syntax check"
bash -n healthcheck.sh

log "Building test image..."
docker buildx build --load --no-cache -t "$IMAGE_NAME" .

indent_gray_output() {
  sed 's/^/  \x1b[90m│ /; s/$/\x1b[0m/'
}

assert_exit_code() {
  local expected="$1"
  shift

  set +e
  "$@" 2>&1 | indent_gray_output
  local actual="${PIPESTATUS[0]}"
  set -e

  if [[ "$actual" -ne "$expected" ]]; then
    exit_failed "FAILED: expected exit code $expected, got $actual"
  fi

  log "PASSED: exit code $actual"
}

log "TEST: Missing vault password"
assert_exit_code 2 \
  docker_run

log "TEST: Invalid mount mode"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD=${VAULT_PASSWORD} \
    -e CRYPTOMATOR_MOUNT_MODE=invalid

log "TEST: Invalid RSYNC_DELETE"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e RSYNC_DELETE=invalid

log "TEST: Invalid SYNC_INTERVAL_MINUTES"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e SYNC_INTERVAL_MINUTES=invalid

log "TEST: Invalid MOUNT_TIMEOUT_SECONDS"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e MOUNT_TIMEOUT_SECONDS=0

log "TEST: Invalid RCLONE_ENABLED"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e RCLONE_ENABLED=invalid

log "TEST: Invalid RCLONE_DESTINATIONS"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e RCLONE_ENABLED=true \
    -e RCLONE_DESTINATIONS=

log "TEST: Invalid RCLONE_CONFIG"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e RCLONE_ENABLED=true \
    -e RCLONE_DESTINATIONS=remote:Vault \
    -e RCLONE_CONFIG=/rclone/missing.conf

log "TEST: Invalid RCLONE_MODE"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e RCLONE_ENABLED=true \
    -e RCLONE_MODE=invalid \
    -e RCLONE_DESTINATIONS=remote:Vault \
    -e RCLONE_CONFIG=/rclone/rclone.conf

log "TEST: Invalid RCLONE_START_DELAY_SECONDS"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e RCLONE_ENABLED=true \
    -e RCLONE_DESTINATIONS=remote:Vault \
    -e RCLONE_CONFIG=/rclone/rclone.conf \
    -e RCLONE_START_DELAY_SECONDS=-1

log "TEST: One-shot vault file copy"
docker_cleanup
before="$(find ./tests/tmp-vault -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
echo "hello from integration test" > ./tests/sync/test-file.txt
assert_exit_code 0 \
  docker_run_without_cleanup \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}"
after="$(find ./tests/tmp-vault -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
if [[ "$before" == "$after" ]]; then
  exit_failed "FAILED: Vault did not change after sync before=$before after=$after"
fi

log "TEST: One-shot vault rclone copy"
docker_cleanup
before="$(find ./tests/rclone-remote -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
echo "hello from integration test" > ./tests/sync/test-file.txt
assert_exit_code 0 \
  docker_run_without_cleanup \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e RCLONE_ENABLED=true \
    -e RCLONE_DESTINATIONS=remote:temp-vault
after="$(find ./tests/rclone-remote -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
if [[ "$before" == "$after" ]]; then
  exit_failed "FAILED: Remote did not change after sync before=$before after=$after"
fi

log "All tests passed!"