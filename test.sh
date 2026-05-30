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

cleanup() {
  docker image rm "$IMAGE_NAME" >/dev/null 2>&1 || true
}

trap cleanup EXIT

log "Preparing test directories and files..."
rm -rf ./tests/sync
mkdir -p ./tests/sync ./tests/vault ./tests/rclone
touch ./tests/rclone/rclone.conf

log "TEST: run.sh syntax check"
bash -n run.sh

log "TEST: healthcheck.sh syntax check"
bash -n healthcheck.sh

log "Building test image without cache..."
docker buildx build \
   --no-cache --pull \
  --load \
  -t "$IMAGE_NAME" .

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
    log_err "FAILED: expected exit code $expected, got $actual"
    return 1
  fi

  log "PASSED: exit code $actual"
}

docker_run() {
  docker run --rm \
    -v "./tests/sync:/sync:ro" \
    -v "./tests/vault:/vault-encrypted" \
    -v "./tests/rclone:/rclone" \
    --cap-add SYS_ADMIN \
    --device /dev/fuse:/dev/fuse \
    --security-opt apparmor:unconfined \
    -e SYNC_INTERVAL_MINUTES=0 \
    "$@" \
    "$IMAGE_NAME"
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

#log "TEST: One-shot sync copies file into vault"
#rm -rf ./tests/sync && mkdir -p ./tests/sync
#before="$(find ./tests/vault -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
#echo "hello from integration test" > ./tests/sync/test-file.txt
#assert_exit_code 0 \
#  docker_run \
#    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
#    -e CRYPTOMATOR_MOUNT_MODE=auto
#after="$(find ./tests/vault -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
#if [[ "$before" == "$after" ]]; then
#  log_err "FAILED: encrypted vault did not change after sync"
#  exit 1
#fi

log "All tests passed!"