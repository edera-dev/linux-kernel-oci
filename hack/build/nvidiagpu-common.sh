#!/bin/sh
set -e

if [ "${KERNEL_FLAVOR}" != "zone-nvidiagpu" ]; then
	return
fi

NV_KMOD_REPO_OWNER=NVIDIA
NV_KMOD_REPO_NAME=open-gpu-kernel-modules
NV_EXTRACT_PATH=/tmp/nvidia-modules
NV_DOWNLOAD_PATH=/tmp/nvidia-modules

rm -rf "$NV_EXTRACT_PATH"

echo "Fetching latest nvidia module release"

LATEST_RELEASE_URL=$(curl -s "https://api.github.com/repos/${NV_KMOD_REPO_OWNER}/${NV_KMOD_REPO_NAME}/releases/latest" | \
    grep -o '"tarball_url": *"[^"]*"' | \
    sed 's/"tarball_url": *"\(.*\)"/\1/')

if [ -z "$LATEST_RELEASE_URL" ]; then
    echo "Failed to fetch latest release URL"
    exit 1
fi

echo "Downloading from: $LATEST_RELEASE_URL"
curl -L -o "$NV_DOWNLOAD_PATH.tar.gz" "$LATEST_RELEASE_URL"
mkdir -p "$NV_EXTRACT_PATH"
tar -xzf "$NV_DOWNLOAD_PATH.tar.gz" -C "$NV_EXTRACT_PATH"

OLDPWD=$(pwd)
cd "$NV_EXTRACT_PATH"/"$NV_KMOD_REPO_OWNER"-*

make -C . NV_VERBOSE=1 SYSSRC="${KERNEL_SRC}" SYSOUT="${KERNEL_OBJ}" TARGET_ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}"  modules

echo "Nvidia build done"

make -C . NV_VERBOSE=1 SYSSRC="${KERNEL_SRC}" SYSOUT="${KERNEL_OBJ}" TARGET_ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}" INSTALL_MOD_PATH="${MODULES_INSTALL_PATH}" modules_install

echo "Nvidia install done"

cd "$OLDPWD"

