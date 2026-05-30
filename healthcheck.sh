#!/usr/bin/env bash
set -Eeuo pipefail

VAULT_DECRYPTED_DIR="${VAULT_DECRYPTED_DIR:-/vault-decrypted}"
HEALTHCHECK_WRITE_TEST="${HEALTHCHECK_WRITE_TEST:-false}"
SYNC_INTERVAL_MINUTES="${SYNC_INTERVAL_MINUTES:-0}"

case "$SYNC_INTERVAL_MINUTES" in
  ''|*[!0-9]*)
    echo "SYNC_INTERVAL_MINUTES must be a non-negative integer"
    exit 1
    ;;
esac

# One-shot mode: container exits after sync anyway, the container exit code is the health signal.
if [[ "$SYNC_INTERVAL_MINUTES" == "0" ]]; then
  exit 0
fi

if ! mountpoint -q "$VAULT_DECRYPTED_DIR"; then
  echo "$VAULT_DECRYPTED_DIR is not a mountpoint"
  exit 1
fi

if ! test -r "$VAULT_DECRYPTED_DIR"; then
  echo "$VAULT_DECRYPTED_DIR is not readable"
  exit 1
fi

if [[ "$HEALTHCHECK_WRITE_TEST" == "true" ]]; then
  test_file="$VAULT_DECRYPTED_DIR/.cryptomator-vault-sync-healthcheck"

  if ! printf 'ok\n' > "$test_file"; then
    echo "failed to write healthcheck file"
    exit 1
  fi

  rm -f "$test_file"
fi

exit 0