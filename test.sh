#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")" || exit 1

IMAGE_NAME=cryptomator-vault-sync:test
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
  fix_test_file_permissions
  rm -rf ./tests/rclone-remote ./tests/sync ./tests/tmp-vault ./tests/state
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

create_state_dir() {
  rm -rf ./tests/state
  mkdir -p ./tests/state
}

docker_cleanup() {
  create_sync_dir
  create_temp_vault
  create_rclone_dir
  create_state_dir
}

fix_test_file_permissions() {
  docker run --rm \
    -v "./tests:/tests" \
    "$IMAGE_NAME" \
    sh -c 'chmod -R a+rwX /tests/rclone-remote /tests/sync /tests/tmp-vault 2>/dev/null || true' \
    >/dev/null 2>&1 || true
}

docker_run_healthcheck() {
  docker run --rm \
    -v "./tests/state:/state" \
    "$@" \
    "$IMAGE_NAME" \
    /healthcheck.sh
}

docker_run_without_cleanup() {
  local exit_code=0
  set +e
  docker run --rm \
    -v "./tests/sync:/sync:ro" \
    -v "./tests/tmp-vault:/vault-encrypted" \
    -v "./tests/rclone:/rclone" \
    -v "./tests/rclone-remote:/rclone-remote" \
    -v "./tests/state:/state" \
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
  docker_run_without_cleanup "$@"
}

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

assert_file_exists() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    exit_failed "FAILED: expected file to exist: $file"
  fi

  log "PASSED: file exists: $file"
}

assert_file_contains_status() {
  local file="$1"
  local expected_status="$2"
  local actual_status=""

  assert_file_exists "$file"

  actual_status="$(awk 'NF {print $NF; exit}' "$file")"

  if [[ "$actual_status" != "$expected_status" ]]; then
    exit_failed "FAILED: expected $file status '$expected_status', got '$actual_status'"
  fi

  log "PASSED: $file status is $expected_status"
}

assert_file_contains_text() {
  local file="$1"
  local expected_text="$2"

  assert_file_exists "$file"

  if ! grep -Fq "$expected_text" "$file"; then
    exit_failed "FAILED: expected $file to contain '$expected_text'"
  fi

  log "PASSED: $file contains expected text"
}

trap cleanup EXIT

log "Preparing test directories and files..."
docker_cleanup

log "TEST: run.sh syntax check"
bash -n run.sh

log "TEST: healthcheck.sh syntax check"
bash -n healthcheck.sh

log "Building test image..."
docker buildx build --load --progress=plain --no-cache -t "$IMAGE_NAME" .

log "TEST: Healthcheck one-shot mode"
docker_cleanup
assert_exit_code 0 \
  docker_run_healthcheck \
    -e SYNC_INTERVAL_MINUTES=0

log "TEST: Healthcheck starting status"
docker_cleanup
printf '2026-05-30 22:10:00 starting\n' > ./tests/state/current-status
assert_exit_code 0 \
  docker_run_healthcheck \
    -e SYNC_INTERVAL_MINUTES=1

log "TEST: Healthcheck idle status"
docker_cleanup
printf '2026-05-30 22:10:00 idle\n' > ./tests/state/current-status
assert_exit_code 0 \
  docker_run_healthcheck \
    -e SYNC_INTERVAL_MINUTES=1

log "TEST: Healthcheck upstream-error status"
docker_cleanup
printf '2026-05-30 22:10:00 upstream-error\n' > ./tests/state/current-status
assert_exit_code 1 \
  docker_run_healthcheck \
    -e SYNC_INTERVAL_MINUTES=1

log "TEST: Healthcheck stopped status"
docker_cleanup
printf '2026-05-30 22:10:00 stopped\n' > ./tests/state/current-status
assert_exit_code 0 \
  docker_run_healthcheck \
    -e SYNC_INTERVAL_MINUTES=1

log "TEST: Healthcheck unknown status"
docker_cleanup
printf '2026-05-30 22:10:00 unknown\n' > ./tests/state/current-status
assert_exit_code 1 \
  docker_run_healthcheck \
    -e SYNC_INTERVAL_MINUTES=1

log "TEST: Missing vault password"
assert_exit_code 2 \
  docker_run
assert_file_contains_status ./tests/state/current-status failed
assert_file_exists ./tests/state/last-error

log "TEST: Invalid CRYPTOMATOR_MOUNT_MODE"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e CRYPTOMATOR_MOUNT_MODE=invalid
assert_file_contains_status ./tests/state/current-status failed
assert_file_exists ./tests/state/last-error

log "TEST: Invalid RSYNC_DELETE"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e RSYNC_DELETE=invalid
assert_file_contains_status ./tests/state/current-status failed
assert_file_exists ./tests/state/last-error

log "TEST: Invalid SYNC_INTERVAL_MINUTES"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e SYNC_INTERVAL_MINUTES=invalid
assert_file_contains_status ./tests/state/current-status failed
assert_file_exists ./tests/state/last-error

log "TEST: Invalid MOUNT_TIMEOUT_SECONDS"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e MOUNT_TIMEOUT_SECONDS=0
assert_file_contains_status ./tests/state/current-status failed
assert_file_exists ./tests/state/last-error

log "TEST: Invalid UPSTREAM_ENABLED"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e UPSTREAM_ENABLED=invalid
assert_file_contains_status ./tests/state/current-status failed
assert_file_exists ./tests/state/last-error

log "TEST: Invalid UPSTREAM_FAIL_ACTION"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e UPSTREAM_FAIL_ACTION=invalid
assert_file_contains_status ./tests/state/current-status failed
assert_file_exists ./tests/state/last-error

log "TEST: Invalid UPSTREAM_DESTINATIONS"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e UPSTREAM_ENABLED=true \
    -e UPSTREAM_DESTINATIONS=
assert_file_contains_status ./tests/state/current-status failed
assert_file_exists ./tests/state/last-error

log "TEST: Invalid UPSTREAM_CONFIG"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e UPSTREAM_ENABLED=true \
    -e UPSTREAM_DESTINATIONS=remote:Vault \
    -e UPSTREAM_CONFIG=/rclone/missing.conf
assert_file_contains_status ./tests/state/current-status failed
assert_file_exists ./tests/state/last-error

log "TEST: Invalid UPSTREAM_MODE"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e UPSTREAM_ENABLED=true \
    -e UPSTREAM_MODE=invalid \
    -e UPSTREAM_DESTINATIONS=remote:Vault \
    -e UPSTREAM_CONFIG=/rclone/rclone.conf
assert_file_contains_status ./tests/state/current-status failed
assert_file_exists ./tests/state/last-error

log "TEST: Invalid UPSTREAM_START_DELAY_SECONDS"
assert_exit_code 2 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e UPSTREAM_ENABLED=true \
    -e UPSTREAM_DESTINATIONS=remote:Vault \
    -e UPSTREAM_CONFIG=/rclone/rclone.conf \
    -e UPSTREAM_START_DELAY_SECONDS=-1
assert_file_contains_status ./tests/state/current-status failed
assert_file_exists ./tests/state/last-error

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
assert_file_contains_status ./tests/state/current-status stopped
assert_file_exists ./tests/state/last-success

log "TEST: RSYNC_DELETE true changes vault after source deletion"
docker_cleanup
echo "file to delete" > ./tests/sync/delete-me.txt
assert_exit_code 0 \
  docker_run_without_cleanup \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e RSYNC_DELETE=true
assert_file_contains_status ./tests/state/current-status stopped
assert_file_exists ./tests/state/last-success
before_delete="$(find ./tests/tmp-vault -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
rm -f ./tests/sync/delete-me.txt
assert_exit_code 0 \
  docker_run_without_cleanup \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e RSYNC_DELETE=true
after_delete="$(find ./tests/tmp-vault -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
if [[ "$before_delete" == "$after_delete" ]]; then
  exit_failed "FAILED: Vault did not change after source deletion with RSYNC_DELETE=true"
fi
assert_file_contains_status ./tests/state/current-status stopped
assert_file_exists ./tests/state/last-success

log "TEST: One-shot vault rclone copy with invalid destination"
assert_exit_code 1 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e UPSTREAM_ENABLED=true \
    -e UPSTREAM_DESTINATIONS=invalid:temp-vault
assert_file_contains_status ./tests/state/current-status failed
assert_file_exists ./tests/state/last-error

log "TEST: One-shot vault rclone copy"
docker_cleanup
before="$(find ./tests/rclone-remote -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
echo "hello from integration test" > ./tests/sync/test-file.txt
assert_exit_code 0 \
  docker_run_without_cleanup \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e UPSTREAM_ENABLED=true \
    -e UPSTREAM_DESTINATIONS=remote:temp-vault
after="$(find ./tests/rclone-remote -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
if [[ "$before" == "$after" ]]; then
  exit_failed "FAILED: Remote did not change after sync before=$before after=$after"
fi
assert_file_contains_status ./tests/state/current-status stopped
assert_file_exists ./tests/state/last-success

log "TEST: One-shot vault rclone copy ignores empty destinations"
docker_cleanup
before="$(find ./tests/rclone-remote/temp-vault -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
echo "hello from empty destination test" > ./tests/sync/test-file.txt
assert_exit_code 0 \
  docker_run_without_cleanup \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e UPSTREAM_ENABLED=true \
    -e UPSTREAM_DESTINATIONS=" | remote:temp-vault | "
after="$(find ./tests/rclone-remote/temp-vault -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
if [[ "$before" == "$after" ]]; then
  exit_failed "FAILED: Remote did not change after sync with empty destination entries"
fi
assert_file_contains_status ./tests/state/current-status stopped
assert_file_exists ./tests/state/last-success

log "TEST: One-shot vault rclone copy to multiple destinations"
docker_cleanup
mkdir -p ./tests/rclone-remote/temp-vault-a ./tests/rclone-remote/temp-vault-b
before_a="$(find ./tests/rclone-remote/temp-vault-a -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
before_b="$(find ./tests/rclone-remote/temp-vault-b -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
echo "hello from multiple destination test" > ./tests/sync/test-file.txt
assert_exit_code 0 \
  docker_run_without_cleanup \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e UPSTREAM_ENABLED=true \
    -e UPSTREAM_DESTINATIONS="remote:temp-vault-a|remote:temp-vault-b"
after_a="$(find ./tests/rclone-remote/temp-vault-a -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
after_b="$(find ./tests/rclone-remote/temp-vault-b -type f -printf '%P %s\n' | sort | sha256sum | awk '{print $1}')"
if [[ "$before_a" == "$after_a" ]]; then
  exit_failed "FAILED: Remote A did not change after sync"
fi
if [[ "$before_b" == "$after_b" ]]; then
  exit_failed "FAILED: Remote B did not change after sync"
fi
assert_file_contains_status ./tests/state/current-status stopped
assert_file_exists ./tests/state/last-success

log "TEST: One-shot upstream fail action continue still exits"
assert_exit_code 1 \
  docker_run \
    -e CRYPTOMATOR_VAULT_PASSWORD="${VAULT_PASSWORD}" \
    -e UPSTREAM_ENABLED=true \
    -e UPSTREAM_FAIL_ACTION=continue \
    -e UPSTREAM_DESTINATIONS=invalid:temp-vault
assert_file_contains_status ./tests/state/current-status failed
assert_file_exists ./tests/state/last-error

log "All tests passed!"