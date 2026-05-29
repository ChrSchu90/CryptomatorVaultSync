#!/bin/bash

cd "$(dirname "$0")" || exit

DOCKER_FILE="Dockerfile"
IMAGE_NAME="cryptomator-vault-sync:dev"
DOCKER_PLATFORM=linux/amd64 # linux/amd64 linux/arm64/v8
CRYPTOMATOR_CLI_VERSION="0.6.2"

docker buildx build --load --progress=plain --platform ${DOCKER_PLATFORM} --build-arg CRYPTOMATOR_CLI_VERSION=${CRYPTOMATOR_CLI_VERSION} -f ${DOCKER_FILE} -t ${IMAGE_NAME} . && \
  docker volume create cryptomator-vault-sync_sync && \
  docker volume create cryptomator-vault-sync_vault-encrypted && \
  docker volume create cryptomator-vault-sync_vault-decrypted && \
  docker run --rm -it --platform ${DOCKER_PLATFORM} \
    -v cryptomator-vault-sync_sync:/sync:ro \
    -v cryptomator-vault-sync_vault-encrypted:/vault-encrypted \
    -v cryptomator-vault-sync_vault-decrypted:/vault-decrypted \
    --cap-add SYS_ADMIN \
    --device /dev/fuse:/dev/fuse \
    --security-opt apparmor:unconfined \
    ${IMAGE_NAME}