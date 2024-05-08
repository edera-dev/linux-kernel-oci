#!/bin/sh
set -e

sudo apt-get update
sudo apt-get install -y \
    build-essential libssl-dev libelf-dev \
    flex bison bc gcc-aarch64-linux-gnu rsync
