#!/bin/bash

cd "$(dirname "$0")" || exit

DOCKER_FILE="Dockerfile"
IMAGE_NAME="cryptomator-vault-sync:dev"
DOCKER_PLATFORM=linux/amd64 # linux/amd64 linux/arm64/v8
CRYPTOMATOR_CLI_VERSION="0.6.2"

docker buildx build --load --progress=plain --platform ${DOCKER_PLATFORM} --build-arg CRYPTOMATOR_CLI_VERSION=${CRYPTOMATOR_CLI_VERSION} -f ${DOCKER_FILE} -t ${IMAGE_NAME} . && \
  docker volume create cryptomator-vault-sync_data && \
  docker run --rm -it --platform ${DOCKER_PLATFORM} \
    -v cryptomator-vault-sync_data:/data \
    --cap-add SYS_ADMIN \
    --device /dev/fuse:/dev/fuse \
    ${IMAGE_NAME}