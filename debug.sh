#!/bin/bash

cd "$(dirname "$0")" || exit

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
DOCKER_FILE=Dockerfile
IMAGE_NAME=cryptomator-vault-sync:dev
DOCKER_PLATFORM=linux/amd64 # linux/amd64 linux/arm64/v8
CRYPTOMATOR_CLI_RELEASE=0.6.2
SUPERCRONIC_RELEASE=0.2.46
RCLONE_RELEASE=1.74.2

mkdir -p ./debug/sync ./debug/vault ./debug/config

# Create Rclone config
# docker run --rm -it --network host -v ./debug/config:/config rclone/rclone config --config /config/rclone.conf

docker buildx build --load --progress=plain --platform ${DOCKER_PLATFORM} --build-arg CRYPTOMATOR_CLI_RELEASE=${CRYPTOMATOR_CLI_RELEASE} --build-arg RCLONE_RELEASE=${RCLONE_RELEASE} --build-arg SUPERCRONIC_RELEASE=${SUPERCRONIC_RELEASE} -f ${DOCKER_FILE} -t ${IMAGE_NAME} . && \
  docker run --rm -it --platform ${DOCKER_PLATFORM} \
    --env-file ./debug/.env \
    -v ./debug/sync:/sync:ro \
    -v ./debug/config:/config:ro \
    -v ./debug/vault:/vault-encrypted \
    -v ./debug/local-remote/vault:/local-remote/vault \
    -e PUID="${HOST_UID}" \
    -e PGID="${HOST_GID}" \
    --cap-add SYS_ADMIN \
    --device /dev/fuse:/dev/fuse \
    --security-opt apparmor:unconfined \
    ${IMAGE_NAME}