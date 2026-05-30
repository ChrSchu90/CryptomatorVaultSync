#!/usr/bin/env bash
set -Eeuo pipefail

SYNC_DIR="${SYNC_DIR:-/sync}"
VAULT_ENCRYPTED_DIR="${VAULT_ENCRYPTED_DIR:-/vault-encrypted}"
VAULT_DECRYPTED_DIR="${VAULT_DECRYPTED_DIR:-/vault-decrypted}"

SYNC_INTERVAL_MINUTES="${SYNC_INTERVAL_MINUTES:-0}"

RCLONE_ENABLED="${RCLONE_ENABLED:-false}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/rclone/rclone.conf}"

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

if [[ ! -d "$SYNC_DIR" ]]; then
  echo "$SYNC_DIR does not exist"
  exit 1
fi

if [[ ! -r "$SYNC_DIR" ]]; then
  echo "$SYNC_DIR is not readable"
  exit 1
fi

if [[ ! -d "$VAULT_ENCRYPTED_DIR" ]]; then
  echo "$VAULT_ENCRYPTED_DIR does not exist"
  exit 1
fi

if [[ ! -f "$VAULT_ENCRYPTED_DIR/vault.cryptomator" ]]; then
  echo "missing vault.cryptomator in $VAULT_ENCRYPTED_DIR"
  exit 1
fi

if [[ ! -f "$VAULT_ENCRYPTED_DIR/masterkey.cryptomator" ]]; then
  echo "missing masterkey.cryptomator in $VAULT_ENCRYPTED_DIR"
  exit 1
fi

if [[ ! -d "$VAULT_ENCRYPTED_DIR/d" ]]; then
  echo "missing encrypted data directory 'd' in $VAULT_ENCRYPTED_DIR"
  exit 1
fi

# /vault-decrypted is only mounted during an active sync cycle.
# It is expected to be unmounted while sleeping or while rclone is running.
if mountpoint -q "$VAULT_DECRYPTED_DIR"; then
  if [[ ! -r "$VAULT_DECRYPTED_DIR" ]]; then
    echo "$VAULT_DECRYPTED_DIR is mounted but not readable"
    exit 1
  fi
fi

if [[ "$RCLONE_ENABLED" != "true" && "$RCLONE_ENABLED" != "false" ]]; then
  echo "RCLONE_ENABLED must be true or false"
  exit 1
fi

if [[ "$RCLONE_ENABLED" == "true" && ! -f "$RCLONE_CONFIG" ]]; then
  echo "rclone config does not exist: $RCLONE_CONFIG"
  exit 1
fi

exit 0