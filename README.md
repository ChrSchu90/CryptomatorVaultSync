# Cryptomator Vault Sync

[![Build](https://github.com/ChrSchu90/CryptomatorVaultSync/actions/workflows/build.yml/badge.svg)](https://github.com/ChrSchu90/CryptomatorVaultSync/actions/workflows/build.yml)

`Cryptomator Vault Sync` syncs files from a plain source directory into a `Cryptomator` vault. The container unlocks the vault temporarily, copies files into the decrypted vault directory, and Cryptomator stores them encrypted in the vault directory.

Optionally, the encrypted vault can be synced to one or more remote destinations using `rclone`, for example Google Drive, OneDrive, SFTP, or any other rclone-supported backend.

```text
/sync -> /vault-decrypted -> /vault-encrypted -> optional rclone remote(s)
```

## ⛔ What this project does not do

This is not a bidirectional sync tool.

Files that already exist inside the Cryptomator vault are not copied back to `/sync`. The sync direction is always:

```text
/sync -> Cryptomator vault
```

Use `RSYNC_DELETE=true` only if `/sync` is intended to be the authoritative source.

## ✔️ Features

- One-way sync from a plain directory into a Cryptomator vault
- Runs in Docker
- Supports FUSE mode
- Supports WebDAV fallback mode using `davfs2`
- `auto` mode tries FUSE first and falls back to WebDAV
- Uses `rsync` for file transfer
- Internal decrypted mount point
- Clean shutdown and unmount handling
- Configurable one-shot or interval-based sync
- Simple exit-code behavior
- Healthcheck
- Optional `rclone` to remote destinations

## 📋 Requirements

The container needs permission to create FUSE mounts.

For all supported modes in the current architecture, use:

```bash
--cap-add SYS_ADMIN \
--device /dev/fuse:/dev/fuse \
--security-opt apparmor:unconfined
```

Explanation:

- `--device /dev/fuse:/dev/fuse` gives the container access to the host FUSE device.
- `--cap-add SYS_ADMIN` allows mount operations inside the container.
- `--security-opt apparmor:unconfined` avoids AppArmor blocking FUSE or mount operations on hosts where this is required.

`apparmor:unconfined` may not be needed on every host. If your setup works without it, you can omit it.

## 📁 Volumes

### `/sync`

Source directory containing files that should be copied into the vault.

> [!TIP]
> Recommended mount mode: read-only, since it is a one-way sync

```bash
-v /path/to/sync:/sync:ro
```

You can also mount multiple source directories as subdirectories below `/sync`. All files below `/sync` will be one-way-synced into the vault while preserving the subdirectory structure.

Example:
```bash
-v /path/to/sync1:/sync/dir1:ro \
-v /path/to/sync2:/sync/dir2:ro \
-v /path/to/sync3:/sync/dir3:ro
```

### `/vault-encrypted`

Encrypted Cryptomator vault directory. This is the directory you also open with the official Cryptomator app.

The directory must already contain an initialized Cryptomator vault. Create the vault beforehand using the [official Cryptomator app](https://cryptomator.org/downloads).

```bash
-v /path/to/vault:/vault-encrypted
```

### `/vault-decrypted`

The decrypted mount is intentionally internal. Even if `/vault-decrypted` is bind-mounted to the host, the host usually will not see the decrypted FUSE/WebDAV mount contents because the mount is created inside the container's mount namespace. Since the sync process runs inside the container, exposing `/vault-decrypted` to the host is not required.

### `/rclone`

Directory for the optional `rclone.conf` in case `UPSTREAM_ENABLED=true`

## ⚙️ Environment variables

| Variable                       | Default            | Description                                                          |
|--------------------------------|-------------------:|----------------------------------------------------------------------|
| `CRYPTOMATOR_VAULT_PASSWORD`   | required           | Password for the Cryptomator vault                                   |
| `CRYPTOMATOR_MOUNT_MODE`       | `auto`             | Mount mode: `fuse`, `webdav`, or `auto`                              |
| `SYNC_DIR`                     | `/sync`            | Source directory inside the container                                |
| `VAULT_ENCRYPTED_DIR`          | `/vault-encrypted` | Encrypted vault directory inside the container                       |
| `RSYNC_DELETE`                 | `false`            | If `true`, delete files in the vault that no longer exist in `/sync` |
| `RSYNC_ARGS`                   | `-rtv --no-owner --no-group --no-perms` | Base rsync arguments                            |
| `RSYNC_EXTRA_ARGS`             | empty              | Additional rsync arguments                                           |
| `MOUNT_TIMEOUT_SECONDS`        | `60`               | Timeout for mount operations                                         |
| `SYNC_INTERVAL_MINUTES`        | `0`                | `0` means one-shot mode; any positive value enables continuous sync  |
| `UPSTREAM_ENABLED`               | `false`            | Enable optional rclone upload/sync after the encrypted vault has been updated |
| `UPSTREAM_MODE`                  | `sync`             | rclone operation mode. Supported values: `sync (one-way vault -> cloud)` , `copy (one-way vault -> cloud, no deletes)` |
| `UPSTREAM_DESTINATIONS`          | empty              | One or more rclone destination paths separated by `\|`. Each remote name must match a section in `rclone.conf` e.g. `onedrive:Vault\|gdrive:Vault` |
| `UPSTREAM_CONFIG`                | `/rclone/rclone.conf` | Path to the rclone configuration file inside the container        |
| `UPSTREAM_EXTRA_ARGS`            | empty              | Additional arguments passed to rclone                                |
| `UPSTREAM_START_DELAY_SECONDS`   | `0`                | Optional delay between rsync (`sync` -> `vault`) and rclone (`vault` -> `remote`) |


## 🏷️ Image Labels

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

## 💻 Docker run

```bash
docker run --rm -it \
  -v /path/to/sync:/sync:ro \
  -v /path/to/vault:/vault-encrypted \
  --cap-add SYS_ADMIN \
  --device /dev/fuse:/dev/fuse \
  --security-opt apparmor:unconfined \
  ghcr.io/chrschu90/cryptomator-vault-sync:1
```

## 🧩 Docker Compose

See: [full example](example/docker-compose.yml)
```yaml
services:
  cryptomator-vault-sync:
    image: ghcr.io/chrschu90/cryptomator-vault-sync:1
    container_name: cryptomator-vault-sync
    cap_add:
      - SYS_ADMIN
    devices:
      - /dev/fuse:/dev/fuse
    security_opt:
      - apparmor:unconfined
    volumes:
      - /path/to/sync:/sync:ro
      - /path/to/vault:/vault-encrypted
```

## ⚡ One-shot mode

Set a 0 interval:

```env
SYNC_INTERVAL_MINUTES=0
```

The container will:

1. Unlock the vault
2. Sync files from `/sync` into the decrypted vault view
3. Unmount the vault
4. Optionally run rclone against `/vault-encrypted`
5. Exit

Use a scheduler for one-shot runs if you do not want the vault to remain unlocked continuously.

## 🔄 Continuous mode

Set a positive interval:

```env
SYNC_INTERVAL_MINUTES=5
```
`SYNC_INTERVAL_MINUTES` defines the delay between completed sync cycles, not a fixed time like cron.

The container will run a full sync cycle every 5 minutes. Each cycle the container will:

1. Unlock the vault
2. Sync files from `/sync` into the decrypted vault view
3. Unmount the vault
4. Optionally run rclone against `/vault-encrypted`
5. Wait until next cycle

In continuous mode, the container does not keep the decrypted vault mounted between sync cycles.

This is intentional. The optional rclone step syncs the encrypted vault directory `/vault-encrypted` to one or more remote destinations. To avoid syncing the vault while Cryptomator is still writing to it, the decrypted vault is unmounted before rclone starts. 
This is also useful when `/vault-encrypted` is bind-mounted to a host directory that is synced upstream by the host itself, for example by Synology Drive, Google Drive, OneDrive, or another backup/sync tool. By unmounting the decrypted vault before the upstream sync starts, the host-side sync tool is more likely to see a stable encrypted vault state instead of files that Cryptomator is still updating.

This gives rclone a stable, closed encrypted vault state to upload.

The trade-off is that each cycle needs to unlock and mount the vault again. This is slightly less efficient, but safer for remote sync targets.

## 🔗 Mount modes

### `FUSE`

Uses Cryptomator CLI's Linux FUSE mount provider.

```env
CRYPTOMATOR_MOUNT_MODE=fuse
```

> [!IMPORTANT]
> #### Test `FUSE` availability
> `FUSE` is much better than the `WebDAV` fallback, to test its availability run the following command on the host:
> ```bash
> ls -l /dev/fuse
> ```
> A typical successful result looks like:
> ```text
> crw-rw-rw- 1 root users 10, 229 ... /dev/fuse
> ```

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

## ☁️ Rclone

To create an rclone config, run the interactive rclone config command:
```bash
docker run --rm -it \
  -v /path/to/rclone:/rclone \
  rclone/rclone config --config /rclone/rclone.conf
```

After the config has been created, set `UPSTREAM_DESTINATIONS` to one or more remote paths you want to sync to, for example:
```env
UPSTREAM_DESTINATIONS=gdrive:CryptomatorVault
```
or with multiple upstreams
```env
UPSTREAM_DESTINATIONS=gdrive:CryptomatorVault|onedrive:CryptomatorVault
```

Multiple destinations are separated by `|`. Do not add spaces around `|`. Avoid using `|` in remote folder names.

The remote name is the section name in rclone.conf:
```text
[gdrive] # <-- This is the remote name
type = drive
scope = drive
token = ...

[onedrive]
type = onedrive
token = ...
```

If your vault should be placed inside a subdirectory of the remote, for example Google Drive:
```text
Root/
└── Vaults/
        └── Backup Vault/
```

set `UPSTREAM_DESTINATIONS` to:
```env
UPSTREAM_DESTINATIONS=gdrive:Vaults/Backup Vault
```

## 💥 Error handling and restarts

The container exits on configuration errors, mount errors, rsync errors, and rclone errors.

This is intentional: failed sync cycles should be visible to the container runtime, schedulers, or monitoring tools.

If you want the container to recover automatically from temporary runtime errors, such as network issues during rclone sync, use a Docker restart policy:
- Use `restart: unless-stopped` for continuous mode.
- Use `restart: "no"` for one-shot usage with an external scheduler, keep restart: "no" so the scheduler can detect failed runs by the container exit code.

## 🏁 Exit codes

| Exit code | Meaning |
|----:|----------------------------------------------------|
| `0` | Success or clean stop via `CTRL+C` / `docker stop` |
| `1` | Runtime error, mount error, or sync error          |
| `2` | Invalid configuration                              |