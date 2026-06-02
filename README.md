# 🐳 Cryptomator Vault Sync [![Build](https://github.com/ChrSchu90/CryptomatorVaultSync/actions/workflows/build.yml/badge.svg)](https://github.com/ChrSchu90/CryptomatorVaultSync/actions/workflows/build.yml)

A Docker container that syncs files one-way from a source directory into a [Cryptomator](https://cryptomator.org) vault, enabling encrypted storage while keeping the vault accessible with the official Cryptomator app.

Optionally, the encrypted vault can be synced to one or more upstream destinations with [rclone](https://rclone.org), for example Google Drive, OneDrive, SFTP, or another rclone-supported provider.

```text
📁 /sync
   ↓ rsync
🔓 /vault-decrypted
   ↓ Cryptomator CLI
🔒 /vault-encrypted
   ↓ rclone (optional)
☁️ upstream destination(s)
```

## Table of contents

- [💡 Use case](#-use-case)
- [⛔ What this project does not do](#-what-this-project-does-not-do)
- [✔️ Features](#-features)
- [📋 Requirements](#-requirements)
- [📁 Directory layout and volumes](#-directory-layout-and-volumes)
  - [`/sync`](#sync)
  - [`/vault-encrypted`](#vault-encrypted)
  - [`/vault-decrypted`](#vault-decrypted)
  - [`/config`](#config)
  - [`/state`](#state)
- [⚙️ Configuration](#-configuration)
- [💻 Docker run](#-docker-run)
- [🧩 Docker Compose](#-docker-compose)
- [🌐 Network mode](#-network-mode)
- [🔄 Sync modes](#-sync-modes)
  - [One-shot mode](#one-shot-mode)
  - [Continuous mode](#continuous-mode)
  - [Dry-run mode](#dry-run-mode)
- [🔗 Cryptomator mount modes](#-cryptomator-mount-modes)
- [🚫 Rsync exclude file](#-rsync-exclude-file)
- [☁️ Rclone upstream sync](#-rclone-upstream-sync)
- [💚 Healthcheck, state files, and restarts](#-healthcheck-state-files-and-restarts)
- [🏷️ Image tags](#-image-tags)
- [🏁 Exit codes](#-exit-codes)

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

If the host does not provide a suitable cloud sync mechanism, the optional [rclone upstream sync](#-rclone-upstream-sync) can sync `/vault-encrypted` to one or more remote destinations.

## ⛔ What this project does not do

This is **not** a bidirectional sync tool.

Files that already exist inside the Cryptomator vault are not copied back to `/sync`. The sync direction is always:

```text
/sync -> Cryptomator vault
```

Use `RSYNC_DELETE=true` only if `/sync` is intended to be the authoritative source.

## ✔️ Features

- One-way sync from a plain source directory into a Cryptomator vault
- Docker-based one-shot or interval-based operation
- FUSE mount mode
- WebDAV fallback mode using `davfs2`
- `auto` mount mode: tries FUSE first, falls back to WebDAV
- `rsync` based file transfer
- Optional `RSYNC_DELETE=true`
- Optional rsync exclude file
- Optional dry-run mode
- Optional password file support
- Optional rclone upstream sync to one or more destinations
- Internal decrypted vault mount point
- Clean shutdown and unmount handling
- Healthcheck and state files for monitoring
- Simple exit-code behavior

## 📋 Requirements

The container needs permission to create FUSE or WebDAV mounts inside the container.

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

Common environment variables pointing into `/config` are:

```env
CRYPTOMATOR_VAULT_PASSWORD_FILE=/config/vault-password
UPSTREAM_CONFIG=/config/rclone.conf
RSYNC_EXCLUDE_FILE=/config/rsync-exclude.txt
```

### `/state`

Optional writable state directory for status files.

The container writes three files:

| File | Description |
|---|---|
| `current-status` | Current container status. Used by the healthcheck in continuous mode. |
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
| `CRYPTOMATOR_MOUNT_MODE` | `auto` | Mount mode: `fuse`, `webdav`, or `auto`. See [Cryptomator mount modes](#-cryptomator-mount-modes). |
| `DRY_RUN` | `false` | Runs rsync in dry-run mode and skips upstream sync. No files are written to the vault or upstream destinations. `/state/last-success` is not updated. |
| `SYNC_DIR` | `/sync` | Source directory inside the container. |
| `VAULT_ENCRYPTED_DIR` | `/vault-encrypted` | Encrypted vault directory inside the container. |
| `STATE_DIR` | `/state` | Directory for state files. |
| `RSYNC_DELETE` | `false` | If `true`, delete files in the vault that no longer exist in `/sync`. |
| `RSYNC_EXCLUDE_FILE` | empty | Optional path to an rsync exclude file. See [Rsync exclude file](#-rsync-exclude-file). |
| `RSYNC_ARGS` | `-rtvi --no-owner --no-group --no-perms` | Base rsync arguments. |
| `RSYNC_EXTRA_ARGS` | empty | Additional rsync arguments. |
| `MOUNT_TIMEOUT_SECONDS` | `60` | Timeout for mount operations. |
| `SYNC_INTERVAL_MINUTES` | `0` | `0` enables one-shot mode. Any positive value enables continuous mode. |
| `UPSTREAM_ENABLED` | `false` | Enable optional rclone upstream sync after the encrypted vault has been updated. |
| `UPSTREAM_FAIL_ACTION` | `exit` | Behavior when rclone fails. `exit` stops the container; `continue` keeps continuous mode running and retries on the next cycle. One-shot mode always exits on upstream errors. |
| `UPSTREAM_MODE` | `sync` | rclone mode: `sync` or `copy`. |
| `UPSTREAM_DESTINATIONS` | empty | One or more rclone destination paths separated by `|`, for example `onedrive:Vault|gdrive:Vault`. |
| `UPSTREAM_CONFIG` | `/config/rclone.conf` | Path to the rclone configuration file. |
| `UPSTREAM_EXTRA_ARGS` | empty | Additional arguments passed to rclone. |
| `UPSTREAM_START_DELAY_SECONDS` | `0` | Optional delay after unmounting the vault before running rclone. |

## 💻 Docker run

Minimal one-shot example without rclone:

```bash
docker run --rm -it \
  --network none \
  -e CRYPTOMATOR_VAULT_PASSWORD='MyVaultPassword' \
  -v /path/to/sync:/sync:ro \
  -v /path/to/vault:/vault-encrypted \
  -v /path/to/state:/state \
  --cap-add SYS_ADMIN \
  --device /dev/fuse:/dev/fuse \
  --security-opt apparmor:unconfined \
  ghcr.io/chrschu90/cryptomator-vault-sync:1
```

## 🧩 Docker Compose

See the full example: [`example/docker-compose.yml`](example/docker-compose.yml)

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
      CRYPTOMATOR_VAULT_PASSWORD_FILE: /config/vault-password
      SYNC_INTERVAL_MINUTES: 0
      UPSTREAM_ENABLED: false
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

### One-shot mode

Set:

```env
SYNC_INTERVAL_MINUTES=0
```

The container will:

1. Unlock the vault.
2. Sync files from `/sync` into the decrypted vault view.
3. Unmount the vault.
4. Optionally run rclone against `/vault-encrypted`.
5. Exit.

Use this mode with an external scheduler such as cron or Synology Task Scheduler.

### Continuous mode

Set a positive interval:

```env
SYNC_INTERVAL_MINUTES=5
```

`SYNC_INTERVAL_MINUTES` defines the delay between completed sync cycles, not a fixed cron-like schedule.

Each cycle will:

1. Unlock the vault.
2. Sync files from `/sync` into the decrypted vault view.
3. Unmount the vault.
4. Optionally run rclone against `/vault-encrypted`.
5. Wait until the next cycle.

The decrypted vault is not kept mounted between cycles. This is intentional: rclone or host-side sync tools should see a stable, closed encrypted vault state instead of files that Cryptomator is still updating.

### Dry-run mode

Set:

```env
DRY_RUN=true
```

Dry-run mode:

- unlocks and mounts the vault normally,
- runs rsync with `--dry-run`,
- does not write files to the vault,
- skips rclone/upstream sync,
- does not update `/state/last-success`.

This is useful for checking what rsync would copy or delete before enabling a real sync, especially when using `RSYNC_DELETE=true`.

## 🔗 Cryptomator mount modes

### `fuse`

Uses Cryptomator CLI's Linux FUSE mount provider.

```env
CRYPTOMATOR_MOUNT_MODE=fuse
```

To check FUSE availability on the host:

```bash
ls -l /dev/fuse
```

A typical successful result looks like:

```text
crw-rw-rw- 1 root users 10, 229 ... /dev/fuse
```

### `webdav`

Uses Cryptomator CLI's WebDAV fallback mounter, detects the generated WebDAV URL from the CLI output, and mounts it internally using `davfs2`.

```env
CRYPTOMATOR_MOUNT_MODE=webdav
```

### `auto`

Tries FUSE first. If FUSE fails, it cleans up and tries WebDAV.

```env
CRYPTOMATOR_MOUNT_MODE=auto
```

This is the default.

## 🚫 Rsync exclude file

You can exclude files or directories from the local sync with an rsync exclude file:

```env
RSYNC_EXCLUDE_FILE=/config/rsync-exclude.txt
```

Example exclude file:

```text
@eaDir/
#recycle/
.DS_Store
Thumbs.db
*.tmp
~$*
```

The file is passed to rsync via `--exclude-from`.

Patterns are interpreted relative to the `/sync` source directory. For example:

```text
/cache/
```

excludes only `/sync/cache/`, while:

```text
cache/
```

excludes directories named `cache` anywhere below `/sync`.

## ☁️ Rclone upstream sync

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

### `sync` vs `copy`

```env
UPSTREAM_MODE=sync
```

Mirrors `/vault-encrypted` to the destination, including deletions.

```env
UPSTREAM_MODE=copy
```

Uploads new and changed files without deleting remote files.

## 💚 Healthcheck, state files, and restarts

In one-shot mode, the container exits after one sync cycle. The container exit code is the primary status signal.

In continuous mode, Docker runs `/healthcheck.sh`. The healthcheck reads `/state/current-status`:

- `starting`, `running`, `idle`, and `stopped` are healthy states.
- unknown states, `failed`, and `upstream-error` are unhealthy states.

Docker's `HEALTHCHECK --retries=3` means the container is only marked unhealthy after repeated failing checks. Once a later cycle succeeds and writes `idle`, the container becomes healthy again.

Recommended restart policies:

| Mode | Restart policy | Reason |
|---|---|---|
| One-shot with external scheduler | `restart: no` | The scheduler should see the container exit code. |
| Continuous mode | `restart: unless-stopped` | Docker can restart the container after fatal runtime errors. |

If `UPSTREAM_FAIL_ACTION=continue` is set in continuous mode, upstream errors do not stop the container. Instead, the container writes `upstream-error` to `/state/current-status`, writes the error to `/state/last-error`, and retries during the next sync cycle.

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
