#!/bin/sh
set -e

if [ "${KERNEL_FLAVOR}" != "zone-nvidiagpu" ]; then
	return
fi

NV_KMOD_REPO_OWNER=NVIDIA
NV_KMOD_REPO_NAME=open-gpu-kernel-modules
NV_EXTRACT_PATH=/tmp/nvidia-modules
NV_DOWNLOAD_PATH=/tmp/nvidia-modules.zip

echo "Fetching latest nvidia module release"

LATEST_RELEASE_URL=$(curl -s "https://api.github.com/repos/${NV_KMOD_REPO_OWNER}/${NV_KMOD_REPO_NAME}/releases/latest" | \
    grep -o '"zipball_url": *"[^"]*"' | \
    sed 's/"zipball_url": *"\(.*\)"/\1/')

if [ -z "$LATEST_RELEASE_URL" ]; then
    echo "Failed to fetch latest release URL"
    exit 1
fi

echo "Downloading from: $LATEST_RELEASE_URL"

curl -L -o "$NV_DOWNLOAD_PATH" "$LATEST_RELEASE_URL"
mkdir -p "$NV_EXTRACT_PATH"
unzip -q "$NV_DOWNLOAD_PATH" -d "$NV_EXTRACT_PATH"

OLDPWD=$(pwd)
cd "$NV_EXTRACT_PATH"/"$NV_KMOD_REPO_OWNER"-*

# make SYSSRC=~/Source/edera-dev/linux-kernel-oci/linux-6.14.6 SYSOUT=/home/bleggett/Source/edera-dev/linux-kernel-oci/obj INSTALL_MOD_PATH=/home/bleggett/Source/edera-dev/linux-kernel-oci/obj modules_instal
make SYSSRC="${KERNEL_SRC}" SYSOUT="${KERNEL_OUT}" TARGET_ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}"  modules

make SYSSRC="${KERNEL_SRC}" SYSOUT="${KERNEL_OUT}" TARGET_ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}" INSTALL_MOD_PATH="${MODULES_INSTALL_PATH}" modules_install

cd "$OLDPWD"
