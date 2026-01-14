#!/bin/bash
set -e

NAME=$(ask "Enter name" "fastvm")
IMAGE=$(ask "Enter image" "ubuntu:22.04")
RAM=$(ask "Enter memory" "2.5")
STORAGE=$(ask "Enter name" "25")

docker rm -f $NAME 2>/dev/null || true

docker run -dit \
  --name $NAME \
  --hostname $NAME \
  --privileged \
  --memory="$RAMg" \
  --storage-opt size=$STORAGEG \
  $IMAGE \
  bash

docker exec $NAME sh -c "
apt update -y &&
apt install -y openssh-server sudo curl wget git
"
