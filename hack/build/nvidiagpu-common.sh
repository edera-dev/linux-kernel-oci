#!/bin/sh
set -e

if [ "${KERNEL_FLAVOR}" != "zone-nvidiagpu" ]; then
	return
fi

NV_KMOD_REPO_OWNER=NVIDIA
NV_KMOD_REPO_NAME=open-gpu-kernel-modules

rm -rf "$NV_EXTRACT_PATH"

echo "Fetching latest nvidia module release"

RELEASE_JSON=$(curl -s "https://api.github.com/repos/${NV_KMOD_REPO_OWNER}/${NV_KMOD_REPO_NAME}/releases/latest")
NV_VERSION=$(echo "$RELEASE_JSON" | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *"\(.*\)"/\1/')
LATEST_RELEASE_URL=$(echo "$RELEASE_JSON" | grep -o '"tarball_url": *"[^"]*"' | sed 's/"tarball_url": *"\(.*\)"/\1/')

if [ -z "$LATEST_RELEASE_URL" ] || [ -z "$NV_VERSION" ]; then
    echo "Failed to fetch latest release information"
    exit 1
fi

echo "Building NVIDIA driver version: $NV_VERSION"

NV_WORKDIR="$(mktemp -d)/nvidia-modules/${NV_VERSION}"
ARCHIVE="$NV_WORKDIR/driver-src.tar.gz"

mkdir -p "$NV_WORKDIR"

curl -L -o "$ARCHIVE" "$LATEST_RELEASE_URL"
tar -xzf "$ARCHIVE" -C "$NV_WORKDIR"

OLDPWD=$(pwd)
cd "$NV_WORKDIR"/"$NV_KMOD_REPO_OWNER"-*

make -C . SYSSRC="${KERNEL_SRC}" SYSOUT="${KERNEL_OBJ}" TARGET_ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}"  modules

echo "Nvidia $NV_VERSION build done"

make -C . SYSSRC="${KERNEL_SRC}" SYSOUT="${KERNEL_OBJ}" TARGET_ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}" INSTALL_MOD_PATH="${MODULES_INSTALL_PATH}" modules_install

echo "Nvidia $NV_VERSION install done"

cd "$OLDPWD"

