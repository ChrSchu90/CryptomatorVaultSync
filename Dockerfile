FROM debian:trixie-slim@sha256:b6e2a152f22a40ff69d92cb397223c906017e1391a73c952b588e51af8883bf8

ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
ARG RCLONE_RELEASE=1.74.2
ARG SUPERCRONIC_RELEASE=0.2.46
ARG CRYPTOMATOR_CLI_RELEASE=0.6.2

ENV DEBIAN_FRONTEND=noninteractive

# Installation of required tools
RUN set -eux; \
    apt-get update; \
    apt-get -y install --no-install-recommends \
        bash \
        curl \
        watch \
        tini \
        ca-certificates \
        fuse3 \
        rsync \
        util-linux; \
    apt-get autoremove -y; \
    apt-get clean; \
    rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/*

# Install Cryptomator CLI
RUN set -eux; \
    apt-get update; \
    apt-get -y install --no-install-recommends wget unzip; \
    case "${TARGETOS}-${TARGETARCH}" in \
        linux-amd64)  CRYPTOMATOR_PLATFORM="linux-x64" ;; \
        linux-arm64)  CRYPTOMATOR_PLATFORM="linux-aarch64" ;; \
        *) echo "Unsupported platform: ${TARGETOS}-${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    DOWNLOAD="https://github.com/cryptomator/cli/releases/download/${CRYPTOMATOR_CLI_RELEASE}/cryptomator-cli-${CRYPTOMATOR_CLI_RELEASE}-${CRYPTOMATOR_PLATFORM}.zip"; \
    wget -qO /tmp/cryptomator.zip "${DOWNLOAD}"; \
    unzip -q /tmp/cryptomator.zip -d /opt; \
    chmod +x /opt/cryptomator-cli/bin/cryptomator-cli; \
    ln -s /opt/cryptomator-cli/bin/cryptomator-cli /usr/local/bin/cryptomator-cli; \
    INSTALLED_VERSION="$(cryptomator-cli --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"; \
    test "${INSTALLED_VERSION}" = "${CRYPTOMATOR_CLI_RELEASE}"; \
    apt-get -y purge wget unzip; \
    apt-get -y autoremove; \
    apt-get -y clean; \
    rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/*

# Install rclone
RUN set -eux; \
    apt-get update; \
    apt-get -y install --no-install-recommends wget; \
    DOWNLOAD="https://github.com/rclone/rclone/releases/download/v${RCLONE_RELEASE}/rclone-v${RCLONE_RELEASE}-${TARGETOS}-${TARGETARCH}.deb"; \
    wget -qO /tmp/rclone.deb "${DOWNLOAD}"; \
    apt-get -y install --no-install-recommends /tmp/rclone.deb; \
    INSTALLED_VERSION="$(rclone version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"; \
    test "$INSTALLED_VERSION" = "$RCLONE_RELEASE"; \
    apt-get -y purge wget; \
    apt-get -y autoremove; \
    apt-get -y clean; \
    rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/*

# Install supercronic
RUN set -eux; \
    apt-get update; \
    apt-get -y install --no-install-recommends wget; \
    DOWNLOAD="https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_RELEASE}/supercronic-${TARGETOS}-${TARGETARCH}"; \
    wget -qO /usr/local/bin/supercronic "${DOWNLOAD}"; \
    chmod 0755 /usr/local/bin/supercronic; \
    INSTALLED_VERSION="$(supercronic -version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"; \
    test "$INSTALLED_VERSION" = "$SUPERCRONIC_RELEASE"; \
    apt-get -y purge wget; \
    apt-get -y autoremove; \
    apt-get -y clean; \
    rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/*

# Add project binaries
COPY --chmod=755 scripts/common.sh /common.sh
COPY --chmod=755 scripts/config.sh /config.sh
COPY --chmod=755 scripts/run.sh /run.sh
COPY --chmod=755 scripts/sync.sh /sync.sh
COPY --chmod=755 scripts/healthcheck.sh /healthcheck.sh

# Healthcheck is only relevant for scheduled mode, check is ignored internally in one-shot mode
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD ["/healthcheck.sh"]

# /sync             Source root dir with files that should be synced
# /vault-encrypted  Encrypted Cryptomator vault mount
# /vault-decrypted  Internal temporary mount point. The host usually cannot see its contents because the mount is created inside the container namespace.
# /state            Optional state files for healthcheck
# /config           Optional config files such as rclone.conf, vault-password, and rsync-exclude.txt
VOLUME ["/sync", "/vault-encrypted", "/config", "/state"]

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/run.sh"]