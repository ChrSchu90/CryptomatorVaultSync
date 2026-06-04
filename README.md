# 🐳 Cryptomator Vault Sync 

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) [![Build](https://github.com/ChrSchu90/CryptomatorVaultSync/actions/workflows/build.yml/badge.svg)](https://github.com/ChrSchu90/CryptomatorVaultSync/actions/workflows/build.yml) [![GHCR](https://img.shields.io/badge/GHCR-cryptomator--vault--sync-blue?logo=github)](https://github.com/ChrSchu90/CryptomatorVaultSync/pkgs/container/cryptomator-vault-sync)

A Docker container that syncs files one-way from a source directory into a [Cryptomator](https://cryptomator.org) vault, enabling encrypted storage while keeping the vault accessible with the official Cryptomator app.

Optionally, the encrypted vault can be synced to one or more upstream destinations with [rclone](https://rclone.org), for example Google Drive, OneDrive, SFTP, or another rclone-supported provider.

```text
📁 /sync
   ↓ rsync
🔓 /vault-decrypted
   ↓ Cryptomator CLI
🔒 /vault-encrypted
   ↓ rclone (optional)
⬆️ upstream destination(s)
```

## 📑 Table of contents

- [💡 Use case](#-use-case)
- [⛔ What this project does not do](#-what-this-project-does-not-do)
- [✔️ Features](#️-features)
- [📋 Requirements](#-requirements)
- [📁 Directory layout and volumes](#-directory-layout-and-volumes)
  - [`/sync`](#sync)
  - [`/vault-encrypted`](#vault-encrypted)
  - [`/vault-decrypted`](#vault-decrypted)
  - [`/config`](#config)
  - [`/state`](#state)
- [⚙️ Configuration](#️-configuration)
  - [`RSYNC_DELETE`](#rsync_delete)
  - [`RSYNC_ARGS`](#rsync_args)
  - [`RSYNC_EXTRA_ARGS`](#rsync_extra_args)
  - [`UPSTREAM_MODE`](#upstream_mode)
  - [`UPSTREAM_CHECK`](#upstream_check)
  - [`UPSTREAM_EXTRA_ARGS`](#upstream_extra_args)
  - [`CRYPTOMATOR_MOUNT_MODE`](#cryptomator_mount_mode)
- [💻 Docker run](#-docker-run)
- [🧩 Docker Compose](#-docker-compose)
- [🌐 Network mode](#-network-mode)
- [🔄 Sync modes](#-sync-modes)
  - [⚡ One-shot mode](#-one-shot-mode)
  - [♾️ Scheduled mode](#️-scheduled-mode)
  - [🧪 Dry-run mode](#-dry-run-mode)
- [⬆️ Rclone upstream sync](#️-rclone-upstream-sync)
  - [`sync`](#upstream_mode)
  - [`copy`](#upstream_mode)
- [💚 Healthcheck, state files, and restarts](#-healthcheck-state-files-and-restarts)
- [🏷️ Image tags](#️-image-tags)
- [🏁 Exit codes](#-exit-codes)
- [🔐 Security notes](#-security-notes)
- [✅ Backup verification](#-backup-verification)
- [🚧 Development and testing](#-development-and-testing)

## 💡 Use case

This project was built for a NAS backup scenario:

- Important files are stored on a Synology NAS or another host.
- These files should be backed up offsite.
- The offsite backup should be encrypted before it leaves the host.
- The encrypted vault should still be accessible with regular Cryptomator clients, for example from a laptop or phone.

A typical Synology setup can look like this:

```text
/sync source dirs -> container -> local encrypted vault -> Synology Cloud Sync -> Google Drive/OneDrive
```

In that setup, rclone is not required inside this container because the host handles the upstream sync.

If the host does not provide a suitable cloud sync mechanism, the optional [rclone upstream sync](#️-rclone-upstream-sync) can sync `/vault-encrypted` to one or more remote destinations.

## ⛔ What this project does not do

This is **not** a bidirectional sync tool.

Files that already exist inside the Cryptomator vault are not copied back to `/sync`. The sync direction is always:

```text
/sync -> Cryptomator vault
```

## ✔️ Features

- One-way sync from a plain source directory into a Cryptomator vault
- Docker-based one-shot or cron-based scheduled operation
- Non-overlapping scheduled sync cycles via internal locking
- FUSE mount mode
- WebDAV fallback mode using `davfs2`
- `auto` mount mode: tries FUSE first, falls back to WebDAV
- `rsync` based file transfer
- Optional `RSYNC_DELETE=true`
- Optional rsync exclude file
- Optional dry-run mode
- Optional password file support
- Optional rclone upstream sync to one or more destinations
- Optional upstream verification via `rclone check`
- Internal decrypted vault mount point
- Clean shutdown and unmount handling
- Healthcheck and state files for monitoring
- Simple exit-code behavior

## 📋 Requirements

The container needs permission to create `FUSE` or `WebDAV` mounts inside the container.

For the current architecture, use:

```yaml
cap_add:
  - SYS_ADMIN
devices:
  - /dev/fuse:/dev/fuse
security_opt:
  - apparmor:unconfined
```

`apparmor:unconfined` may not be needed on every host. If your setup works without it, you can omit it.

## 📁 Directory layout and volumes

A typical host-side setup can look like this:

```text
/docker/cryptomator-vault-sync/
├── sync/
│   ├── Documents/
│   ├── Photos/
│   └── Important.txt
├── vault/
│   ├── vault.cryptomator
│   ├── masterkey.cryptomator
│   └── d/
├── config/
│   ├── vault-password
│   ├── rclone.conf
│   └── rsync-exclude.txt
└── state/
    ├── current-status
    ├── last-success
    └── last-error
```

These directories are mounted into the container as:

| Container path | Required | Recommended mode | Description |
|---|---:|---|---|
| [`/sync`](#sync) | yes | read-only | Source files that should be copied into the decrypted vault view. |
| [`/vault-encrypted`](#vault-encrypted) | yes | read-write | Existing initialized Cryptomator vault. |
| [`/config`](#config) | optional | read-only | Optional config files such as `vault-password`, `rclone.conf`, and `rsync-exclude.txt`. |
| [`/state`](#state) | optional | read-write | Status files used by the healthcheck and external monitoring. |

### `/sync`

Source directory containing files that should be copied into the vault.

Recommended mount mode: read-only.

```bash
-v /path/to/sync:/sync:ro
```

You can also mount multiple host directories below `/sync`. All files below `/sync` will be one-way synced into the vault while preserving the subdirectory structure.

```yaml
volumes:
  - /path/to/dir1:/sync/dir1:ro
  - /path/to/dir2:/sync/dir2:ro
  - /path/to/dir3:/sync/dir3:ro
```

### `/vault-encrypted`

Encrypted Cryptomator vault directory. This is the directory you also open with the official Cryptomator app.

The directory must already contain an initialized Cryptomator vault. Create the vault beforehand using the [official Cryptomator app](https://cryptomator.org/downloads).

```bash
-v /path/to/vault:/vault-encrypted
```

### `/vault-decrypted`

Internal temporary mount point used by the container.

Do **not** mount this directory from the host. Even if `/vault-decrypted` is bind-mounted, the host usually will not see the decrypted FUSE/WebDAV mount contents because the mount is created inside the container's mount namespace.

### `/config`

Optional read-only configuration directory.

It can contain:

```text
/config/vault-password
/config/rclone.conf
/config/rsync-exclude.txt
```

Example config files:
- [`rsync-exclude.txt`](example/config/rsync-exclude.txt)
- [`vault-password.example`](example/config/vault-password.example)
- `rclone.conf` can be generated with an [interactive rclone container](#️-rclone-upstream-sync)

### `/state`

Optional writable state directory for status files.

The container writes three files:

| File | Description |
|---|---|
| `current-status` | Current container status. Used by the healthcheck in scheduled mode. |
| `last-success` | Timestamp of the last fully successful real sync cycle. Not updated during dry-run mode. |
| `last-error` | Timestamp and message of the last error. |

Example:

```text
/state/current-status
2026-05-30 22:10:00 idle

/state/last-success
2026-05-30 22:10:00

/state/last-error
2026-05-30 22:05:00 Rclone failed for destination 'gdrive:Vault' with exit code 1
```

Possible `current-status` values:

| Status | Meaning |
|---|---|
| `starting` | Container has started and is validating configuration. |
| `running` | A sync cycle is currently running. |
| `idle` | Last sync cycle completed successfully and the container is waiting for the next cycle. |
| `upstream-error` | Local vault sync completed, but optional upstream sync failed. |
| `failed` | The container hit a fatal error and is exiting. |
| `stopped` | The container stopped cleanly. |

## ⚙️ Configuration

| Variable | Default | Description |
|---|---:|---|
| `CRYPTOMATOR_VAULT_PASSWORD` | required if no password file is used | Password for the Cryptomator vault. If both password variables are set, this value takes precedence. |
| `CRYPTOMATOR_VAULT_PASSWORD_FILE` | unset | Full path to a file containing the Cryptomator vault password. Used only when `CRYPTOMATOR_VAULT_PASSWORD` is not set. |
| `CRYPTOMATOR_MOUNT_MODE` | `auto` | Mount mode: `fuse`, `webdav`, or `auto`. See [Cryptomator mount modes](#cryptomator_mount_mode). |
| `DRY_RUN` | `false` | Runs rsync in dry-run mode and skips upstream sync. No files are written to the vault or upstream destinations. `/state/last-success` is not updated. |
| `SYNC_DIR` | `/sync` | Source directory inside the container. |
| `VAULT_ENCRYPTED_DIR` | `/vault-encrypted` | Encrypted vault directory inside the container. |
| `STATE_DIR` | `/state` | Directory for state files. |
| `RSYNC_DELETE` | `false` | If `true`, delete files in the vault that no longer exist in `/sync`. Only enable this if `/sync` is the authoritative source. Use `DRY_RUN=true` first to review what would be deleted. |
| `RSYNC_EXCLUDE_FILE` | empty | Optional path to an rsync exclude file. See [Rsync exclude file](#rsync_exclude_file). |
| `RSYNC_ARGS` | `-rtvi --no-owner --no-group --no-perms` | Base rsync arguments. |
| `RSYNC_EXTRA_ARGS` | empty | Additional rsync arguments. |
| `MOUNT_TIMEOUT_SECONDS` | `60` | Timeout for mount operations. |
| `SYNC_CRON` | empty | Cron schedule for scheduled mode. Leave empty for one-shot mode. Uses standard 5-field cron syntax, for example `*/5 * * * *`. |
| `UPSTREAM_ENABLED` | `false` | Enable optional rclone upstream sync after the encrypted vault has been updated. |
| `UPSTREAM_CHECK` | `false` | If `true`, runs `rclone check` after each successful upstream sync/copy destination. This verifies that source and destination match, but can increase runtime and provider API usage. |
| `UPSTREAM_FAIL_ACTION` | `continue` | Behavior when rclone or upstream check fails. `continue` marks the status as `upstream-error` and retries on the next scheduled cycle. `exit` marks the sync cycle as failed. One-shot mode always exits on upstream errors. |
| `UPSTREAM_MODE` | `sync` | rclone operation mode. `sync` mirrors the local encrypted vault to the destination, including deletions. This is the recommended mode when the upstream destination should be an exact copy of the local vault. `copy` uploads new and changed files without deleting remote files, but may leave old encrypted vault files at the destination. |
| `UPSTREAM_DESTINATIONS` | empty | One or more rclone destination paths separated by `|`, for example `onedrive:Vault|gdrive:Vault`. |
| `UPSTREAM_CONFIG` | `/config/rclone.conf` | Path to the rclone configuration file. |
| `UPSTREAM_EXTRA_ARGS` | empty | Additional arguments passed to rclone. |
| `UPSTREAM_START_DELAY_SECONDS` | `0` | Optional delay after unmounting the vault before running rclone. |

### `RSYNC_DELETE`

Only enable `RSYNC_DELETE=true` if `/sync` is the authoritative source.
When enabled, files that no longer exist in `/sync` will also be deleted from the vault during sync.

Before enabling this option for the first time, run with `DRY_RUN=true` and review the rsync output.

### `RSYNC_ARGS`

```env
RSYNC_ARGS=-rtvi --no-owner --no-group --no-perms
```

| Option       | Meaning                            |
| ------------ | ---------------------------------- |
| `-r`         | Copy directories recursively.      |
| `-t`         | Preserve modification times.       |
| `-v`         | Enable verbose output.             |
| `-i`         | Show itemized changes in the logs. |
| `--no-owner` | Do not preserve file owner.        |
| `--no-group` | Do not preserve file group.        |
| `--no-perms` | Do not preserve file permissions.  |

### `RSYNC_EXTRA_ARGS`

`RSYNC_EXTRA_ARGS` can be used to pass additional arguments to `rsync`. These arguments are appended to the default `RSYNC_ARGS`. For all available options, see the [rsync(1) man page](https://www.man7.org/linux/man-pages/man1/rsync.1.html).

```env
# Use checksums instead of size and modification time to detect changed files
RSYNC_EXTRA_ARGS=--checksum

# Skip files that already exist in the vault
RSYNC_EXTRA_ARGS=--ignore-existing

# Skip files larger than 500M
RSYNC_EXTRA_ARGS=--max-size=500M

# Limit bandwidth to approximately 5000 KiB/s
RSYNC_EXTRA_ARGS=--bwlimit=5000
```

### `UPSTREAM_MODE`

`UPSTREAM_MODE` controls how rclone writes `/vault-encrypted` to the configured upstream destination.

| Option   | Meaning                            |
| -------- | ---------------------------------- |
| `sync`   | Mirrors the local encrypted vault to the destination, including deletions. This is recommended when the upstream destination should be an exact copy of the local Cryptomator vault.      |
| `copy`   | Uploads new and changed files without deleting remote files. This can be useful for conservative uploads, but it may leave old encrypted vault files at the destination and should not be treated as an exact mirror.       |

### `UPSTREAM_CHECK`

When enabled, the container runs `rclone check` for each upstream destination after `rclone sync` or `rclone copy` completed successfully.

This can help detect incomplete or inconsistent upstream transfers, but it may increase runtime and provider API usage. For cloud providers with strict rate limits, consider reducing rclone concurrency via `UPSTREAM_EXTRA_ARGS`.

```env
UPSTREAM_CHECK=true
```

### `UPSTREAM_EXTRA_ARGS`

`UPSTREAM_EXTRA_ARGS` can be used to pass additional arguments to `rclone`. These arguments are appended to the rclone command. See the official [rclone global flags documentation](https://rclone.org/flags/).

```env
# Limit rclone bandwidth to 8M
UPSTREAM_EXTRA_ARGS=--bwlimit 8M

# Reduce parallel transfers and checks
UPSTREAM_EXTRA_ARGS=--transfers 2 --checkers 4

# Set the Google Drive upload chunk size
UPSTREAM_EXTRA_ARGS=--drive-chunk-size 64M

# Enable verbose rclone logging for debugging
UPSTREAM_EXTRA_ARGS=-vv
```

### `RSYNC_EXCLUDE_FILE`

You can exclude files or directories from the local sync with an rsync exclude file. The file is passed to rsync via `--exclude-from`.

Patterns are interpreted relative to the `/sync` source directory. [See example rsync-exclude.txt](/example/config/rsync-exclude.txt)

```env
RSYNC_EXCLUDE_FILE=/config/rsync-exclude.txt
```

### `CRYPTOMATOR_MOUNT_MODE`

| Option   | Meaning                            |
| -------- | ---------------------------------- |
| `fuse`   | Uses Cryptomator CLI's Linux FUSE mount provider.     |
| `webdav`   | Uses Cryptomator CLI's WebDAV fallback mounter, detects the generated WebDAV URL from the CLI output, and mounts it internally using `davfs2`.       |
| `auto`   | Tries FUSE first. If FUSE fails, it cleans up and tries WebDAV. This is the default.       |

To check `FUSE` availability on the host:

```bash
ls -l /dev/fuse
```

A typical successful result looks like:

```text
crw-rw-rw- 1 root users 10, 229 ... /dev/fuse
```

## 💻 Docker run

Minimal [dry-run](#-dry-run-mode) example without rclone:

```bash
docker run --rm -it \
  --network none \
  -v /path/to/sync:/sync:ro \
  -v /path/to/vault:/vault-encrypted \
  -v /path/to/state:/state \
  --cap-add SYS_ADMIN \
  --device /dev/fuse:/dev/fuse \
  --security-opt apparmor:unconfined \
  -e CRYPTOMATOR_VAULT_PASSWORD='MyVaultPassword' \
  -e DRY_RUN='true' \
  ghcr.io/chrschu90/cryptomator-vault-sync:1
```

## 🧩 Docker Compose

Choose the example that matches your upstream sync strategy:

| File | Use case |
|---|---|
| [`docker-compose.no-upstream.yml`](example/docker-compose.no-upstream.yml) | Local encrypted vault only. Use this when the host handles upstream sync externally, for example with Synology Cloud Sync, Google Drive Desktop, or OneDrive. |
| [`docker-compose.rclone-upstream.yml`](example/docker-compose.rclone-upstream.yml) | Container-managed upstream sync via rclone. |
| [`docker-compose.full.yml`](example/docker-compose.full.yml) | Full reference example with all relevant options. |

You can also use an [`environment file`](example/.env.example):

```yml
env_file:
  - .env
```

Minimal [dry-run](#-dry-run-mode) example without rclone:

```yaml
services:
  cryptomator-vault-sync:
    image: ghcr.io/chrschu90/cryptomator-vault-sync:1
    container_name: cryptomator-vault-sync
    network_mode: none
    cap_add:
      - SYS_ADMIN
    devices:
      - /dev/fuse:/dev/fuse
    security_opt:
      - apparmor:unconfined
    environment:
      CRYPTOMATOR_VAULT_PASSWORD: MyVaultPassword
      DRY_RUN: true
    volumes:
      - /path/to/sync:/sync:ro
      - /path/to/vault:/vault-encrypted
      - /path/to/config:/config:ro
      - /path/to/state:/state
```

## 🌐 Network mode

### Without rclone

If `UPSTREAM_ENABLED=false`, the container does not need outbound network access during normal operation.

In this mode you can disable networking:

```yaml
network_mode: none
```

or:

```bash
--network none
```

### With rclone

If `UPSTREAM_ENABLED=true`, the container needs network access so rclone can reach the configured destination, for example another machine in the local network, Google Drive, or OneDrive.

Use Docker's default bridge network or omit `network_mode`.

## 🔄 Sync modes

### ⚡ One-shot mode

Leave `SYNC_CRON` empty:

```env
SYNC_CRON=
```

The container runs one sync cycle and exits.

1. Unlock the vault.
2. Sync files from `/sync` into the decrypted vault view.
3. Unmount the vault.
4. Optionally run rclone against `/vault-encrypted`.
5. Exit.

Use this mode with an external scheduler such as cron or Synology Task Scheduler.

### ♾️ Scheduled mode

Scheduled mode is handled by [supercronic](https://github.com/aptible/supercronic) inside the container. Each scheduled run starts `/sync.sh`. Sync cycles are protected against overlap by a lock file, so a scheduled run is skipped if the previous sync cycle is still running.

Set a cron expression:

```env
SYNC_CRON=*/5 * * * *
```

In Docker Compose, quote cron expressions:

```yml
SYNC_CRON: "*/5 * * * *"
```

The container starts a sync cycle according to the cron schedule. Sync cycles are protected against overlap. If a previous cycle is still running when the next scheduled run starts, that run is skipped.

Each cycle will:

1. Unlock the vault.
2. Sync files from `/sync` into the decrypted vault view.
3. Unmount the vault.
4. Optionally run rclone against `/vault-encrypted`.
5. Wait until the next cycle.

The decrypted vault is not kept mounted between cycles. This is intentional: rclone or host-side sync tools should see a stable, closed encrypted vault state instead of files that Cryptomator is still updating.

### 🧪 Dry-run mode

Set:

```env
DRY_RUN=true
```

Dry-run mode:

- Unlocks and mounts the vault normally.
- Runs rsync with `--dry-run`.
- Does not write files to the vault.
- Skips rclone/upstream sync.
- Does not update `/state/last-success` because no real sync was performed.

This is useful for checking what rsync would copy or delete before enabling a real sync, especially when using `RSYNC_DELETE=true`.

## ⬆️ Rclone upstream sync

rclone is optional. Enable it only when the container itself should upload or copy the encrypted vault to one or more upstream destinations.

```env
UPSTREAM_ENABLED=true
UPSTREAM_DESTINATIONS=gdrive:CryptomatorVault
UPSTREAM_CONFIG=/config/rclone.conf
```

Create an rclone config interactively:

```bash
docker run --rm -it \
  -v /path/to/config:/config \
  rclone/rclone config --config /config/rclone.conf
```

The remote name is the section name in `rclone.conf`:

```text
[gdrive] # <-- remote name
type = drive
token = ...

[onedrive]
type = onedrive
token = ...
```

Multiple destinations are separated by `|`:

```env
UPSTREAM_DESTINATIONS=gdrive:CryptomatorVault|onedrive:CryptomatorVault
```

Spaces around `|` are ignored. Avoid using `|` in remote folder names.

If your vault should be placed inside a subdirectory of the remote, for example:

```text
Root/
└── Vaults/
    └── Backup Vault/
```

set:

```env
UPSTREAM_DESTINATIONS=gdrive:Vaults/Backup Vault
```

`UPSTREAM_MODE` controls whether rclone uses `copy` or `sync`. See [Configuration](#upstream_mode).

## 💚 Healthcheck, state files, and restarts

In one-shot mode, the container exits after one sync cycle. The container exit code is the primary status signal.

In scheduled mode, Docker runs `/healthcheck.sh`. The healthcheck reads `/state/current-status`:

- `starting`, `running`, `idle`, and `stopped` are healthy states.
- unknown states, `failed`, and `upstream-error` are unhealthy states.

Docker's `HEALTHCHECK --retries=3` means the container is only marked unhealthy after repeated failing checks. Once a later cycle succeeds and writes `idle`, the container becomes healthy again.

Recommended restart policies:

| Mode | Restart policy | Reason |
|---|---|---|
| One-shot with external scheduler | `restart: "no"` | The scheduler should see the container exit code. |
| Scheduled mode | `restart: unless-stopped` | Docker can restart the container after fatal runtime errors. |

If `UPSTREAM_FAIL_ACTION=continue` is set in scheduled mode, upstream errors do not stop the container. Instead, the container writes `upstream-error` to `/state/current-status`, writes the error to `/state/last-error`, and retries during the next sync cycle.

## 🏷️ Image tags

This image follows semantic versioning.
Use specific version tags for reproducibility. Preview tags are not recommended for production.

- `latest` – Most recent stable release
- `1` – Latest stable release in major version `1`
- `1.2` – Latest stable release in minor version `1.2`
- `1.2.3` – Specific stable patch version (fully pinned)
- `preview` – Latest preview build
- `1-preview` – Latest preview for major version `1`
- `1.2-preview` – Latest preview for minor version `1.2`
- `1.2.3-preview` – Latest preview for patch version `1.2.3`
- `1.2.3-beta.1` – Specific preview build (fully pinned)

## 🏁 Exit codes

| Exit code | Meaning |
|---:|---|
| `0` | Success or clean stop via `CTRL+C` / `docker stop`. |
| `1` | Runtime error, mount error, rsync error, or upstream error. |
| `2` | Invalid configuration. |

## 🔐 Security notes

This container needs elevated mount permissions to unlock and mount a Cryptomator vault inside the container. Treat it as a privileged workload and only mount the host paths it really needs.

Recommended checklist:

| Area | Recommendation |
|---|---|
| `/sync` | Mount read-only whenever possible. |
| `/config` | Mount read-only and protect files such as `vault-password` and `rclone.conf`. |
| `/state` | Keep writable, but do not store secrets there. |
| `/vault-decrypted` | Do not mount from the host. It is an internal temporary mount point. |
| Host mounts | Avoid broad mounts such as `/`, `/volume1`, or a full home directory. |
| Network | Use `network_mode: none` when `UPSTREAM_ENABLED=false`. |
| rclone | Protect `rclone.conf`, because it may contain cloud access tokens. |
| Passwords | Prefer `CRYPTOMATOR_VAULT_PASSWORD_FILE` over putting the vault password directly into Compose files. |

## ✅ Backup verification

A backup is only useful if it can be opened and the expected files are readable.

This project writes data into a standard Cryptomator vault. Verification should therefore be done with the official Cryptomator app or another trusted Cryptomator client.

Recommended verification steps:

1. Let the container finish a successful real sync cycle.
2. Check `/state/last-success` to confirm when the last successful sync happened.
3. Make sure the encrypted vault has been synced to the upstream destination.
4. On another device, download or sync the encrypted vault from the upstream destination.
5. Open the vault with the official Cryptomator app.
6. Verify that important files are visible and readable.
7. Repeat this regularly.

Do not only check that encrypted files exist in the remote destination. The important test is whether the vault can be unlocked and the expected decrypted files can be read.

If the upstream sync is handled by the host, for example Synology Cloud Sync, also verify that the host-side sync has completed before opening the vault on another device.

`DRY_RUN=true` does not update `/state/last-success` and does not create a real backup. Use a real sync cycle for backup verification.

## 🚧 Development and testing

The container entrypoint and sync logic are split into multiple shell scripts:

| File | Purpose |
|---|---|
| `scripts/common.sh` | Shared helper functions for logging, timestamps, state files, exit handling, and small utility functions. |
| `scripts/config.sh` | Central place for defaults, configuration validation, runtime path validation, and vault password loading. |
| `scripts/run.sh` | Container entrypoint. Selects one-shot or scheduled mode, validates startup configuration, and starts `supercronic` when `SYNC_CRON` is set. |
| `scripts/sync.sh` | Executes one complete sync cycle: validates runtime paths, loads the vault password, mounts the vault, runs rsync, unmounts the vault, and optionally runs rclone/upstream checks. |
| `scripts/healthcheck.sh` | Docker healthcheck script. In scheduled mode, reads `/state/current-status` and maps known states to healthy or unhealthy. |
| `scripts/debug.sh` | Local helper script for manual image builds, debug runs, and interactive testing during development. |

For manual debugging, `sync.sh` can also be executed directly inside a running container to trigger one sync cycle.

```bash
docker exec -it cryptomator-vault-sync /sync.sh
```

This does not start the scheduler. It only runs one sync cycle. If another sync cycle is already running, the internal lock prevents overlapping runs.

Run the local test suite with:

```bash
./tests/test.sh
```

The test script:

- Checks shell syntax for all project scripts:
  - common.sh
  - config.sh
  - run.sh
  - sync.sh
  - healthcheck.sh
- Builds the Docker image without cache.
- Validates configuration errors.
- Runs one-shot sync integration tests.
- Tests scheduled-mode configuration and healthcheck behavior.
- Tests rclone/upstream behavior.
- Tests optional upstream verification with UPSTREAM_CHECK=true.
- Tests state files and status handling.


The tests require Docker Buildx and a host environment that supports the required container mount permissions.