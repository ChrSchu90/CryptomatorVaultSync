# Cryptomator Vault Sync

[![Build](https://github.com/ChrSchu90/CryptomatorVaultSync/actions/workflows/build.yml/badge.svg)](https://github.com/ChrSchu90/CryptomatorVaultSync/actions/workflows/build.yml)

One-way Docker-based file sync into an encrypted Cryptomator vault, with `FUSE` support and `WebDAV` fallback.

`CryptomatorVaultSync` syncs files from a plain sync directory into a Cryptomator vault. The container unlocks the vault temporarily, copies files into the decrypted vault view, and Cryptomator stores them encrypted in the vault directory.

## ✨ What this project does

```text
/sync -> /vault-decrypted -> /vault-encrypted
```

- `/sync` is the plain source directory containing files that should be copied into the vault.
- `/vault-decrypted` is an internal temporary mount point inside the container.
- `/vault-encrypted` is the encrypted Cryptomator vault directory.

The decrypted mount is intentionally internal. Even if `/vault-decrypted` is bind-mounted to the host, the host usually will not see the decrypted FUSE/WebDAV mount contents because the mount is created inside the container's mount namespace. Since the sync process runs inside the container, exposing `/vault-decrypted` to the host is not required.

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
- Healthcheck with optional write of test file

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

You can also mount multiple source directories as subdirectories below /sync. All files below /sync will be synced into the vault while preserving the subdirectory structure.

Example:
```bash
-v /path/to/sync1:/sync/dir1:ro \
-v /path/to/sync2:/sync/dir2:ro \
-v /path/to/sync3:/sync/dir3:ro
```

### `/vault-encrypted`

Encrypted Cryptomator vault directory.

This is the directory you also open with the official Cryptomator app.

```bash
-v /path/to/vault:/vault-encrypted
```

### `/vault-decrypted`

Internal temporary mount point used inside the container.

Do not bind-mount this path for normal one-way sync usage.

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
| `HEALTHCHECK_WRITE_TEST`       | `false`            | If `true`, enables an extended write test inside the healthcheck     |

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

Set:

```env
SYNC_INTERVAL_MINUTES=0
```

The container will:

1. Unlock the vault
2. Sync files from `/sync` into the decrypted vault view
3. Unmount the vault
4. Exit

Use a scheduler for one-shot runs if you do not want the vault to remain unlocked continuously.

## 🔄 Continuous mode

Set a positive interval:

```env
SYNC_INTERVAL_MINUTES=5
```

The container will keep the vault mounted and run `rsync` every 5 minutes.

Use this only if you are comfortable with the vault staying unlocked while the container is running.

## Mount modes

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
>A typical successful result looks like:
>```text
>crw-rw-rw- 1 root users 10, 229 ... /dev/fuse
>```

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

## 🚦 Exit codes

| Exit code | Meaning |
|----:|----------------------------------------------------|
| `0` | Success or clean stop via `CTRL+C` / `docker stop` |
| `1` | Runtime error, mount error, or sync error          |
| `2` | Invalid configuration                              |
