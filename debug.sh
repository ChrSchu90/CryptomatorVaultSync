#!/bin/bash

cd "$(dirname "$0")" || exit

DOCKER_FILE=Dockerfile
IMAGE_NAME=cryptomator-vault-sync:dev
DOCKER_PLATFORM=linux/amd64 # linux/amd64 linux/arm64/v8
CRYPTOMATOR_CLI_RELEASE=0.6.2
RCLONE_RELEASE=1.74.2

mkdir -p ./debug/sync ./debug/vault ./debug/rclone

# Create Rclone config
#docker run --rm -it -v ./debug/rclone:/rclone rclone/rclone config --config /rclone/rclone.conf

docker buildx build --load --progress=plain --platform ${DOCKER_PLATFORM} --build-arg CRYPTOMATOR_CLI_RELEASE=${CRYPTOMATOR_CLI_RELEASE} --build-arg RCLONE_RELEASE=${RCLONE_RELEASE} -f ${DOCKER_FILE} -t ${IMAGE_NAME} . && \
  docker run --rm -it --platform ${DOCKER_PLATFORM} \
    --env-file ./debug/.env \
    -v ./debug/sync:/sync:ro \
    -v ./debug/vault:/vault-encrypted \
    -v ./debug/rclone:/rclone \
    --cap-add SYS_ADMIN \
    --device /dev/fuse:/dev/fuse \
    --security-opt apparmor:unconfined \
    ${IMAGE_NAME}