#!/bin/bash

cd "$(dirname "$0")" || exit

DOCKER_FILE="Dockerfile"
IMAGE_NAME="cryptomator-vault-sync:dev"
DOCKER_PLATFORM=linux/amd64 # linux/amd64 linux/arm64/v8
CRYPTOMATOR_CLI_VERSION="0.6.2"

docker buildx build --load --progress=plain --platform ${DOCKER_PLATFORM} --build-arg CRYPTOMATOR_CLI_VERSION=${CRYPTOMATOR_CLI_VERSION} -f ${DOCKER_FILE} -t ${IMAGE_NAME} . && \
  docker run --rm -it --platform ${DOCKER_PLATFORM} \
    --env-file ./debug/.env \
    -v ./debug/sync:/sync:ro \
    -v ./debug/vault-encrypted:/vault-encrypted \
    -v ./debug/vault-decrypted:/vault-decrypted \
    --cap-add SYS_ADMIN \
    --device /dev/fuse:/dev/fuse \
    --security-opt apparmor:unconfined \
    ${IMAGE_NAME}