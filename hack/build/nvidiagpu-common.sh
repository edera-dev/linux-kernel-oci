#!/bin/sh
set -e

# TODO(bleggett) upstream DOES support arm64 builds in theory but following their docs for it results in build
# failures due to missing symbols that shouldn't be missing, so defer until/if we care.
if [ "${KERNEL_FLAVOR}" != "zone-nvidiagpu" ] || [ "${TARGET_ARCH_STANDARD}" != "x86_64" ]; then
	return
fi

NV_KMOD_REPO_OWNER=NVIDIA
NV_KMOD_REPO_NAME=open-gpu-kernel-modules

rm -rf "$NV_EXTRACT_PATH"

# This will also be used to later fetch the correct firmware blob from the userspace pkg
NV_VERSION="$(echo "${KERNEL_VERSION}" | awk -F'-nvidia-' '{print $2}')"

if [ -z "$NV_VERSION" ]; then
	echo "Could not extract nvidia driver version from ${NV_VERSION}!"
	exit 1
fi

echo "Fetching nvidia module release: $NV_VERSION"

NV_WORKDIR="$(mktemp -d)/nvidia-modules/${NV_VERSION}"
mkdir -p "$NV_WORKDIR"

if [ -n "${NVIDIA_MODULES_PATH}" ] && [ -f "${NVIDIA_MODULES_PATH}" ]; then
    ARCHIVE="${NVIDIA_MODULES_PATH}"
else
    RELEASE_JSON=$(curl -s --retry 5 --retry-delay 2 --retry-max-time 30 --retry-all-errors "https://api.github.com/repos/${NV_KMOD_REPO_OWNER}/${NV_KMOD_REPO_NAME}/releases/tags/${NV_VERSION}")
    TARBALL_URL=$(echo "$RELEASE_JSON" | grep -o '"tarball_url": *"[^"]*"' | sed 's/"tarball_url": *"\(.*\)"/\1/')
    if [ -z "$TARBALL_URL" ]; then
        echo "Failed to fetch release information for version $NV_VERSION"
        exit 1
    fi
    ARCHIVE="$NV_WORKDIR/driver-src.tar.gz"
    curl -L -o "$ARCHIVE" "$TARBALL_URL"
fi

echo "Building NVIDIA driver version: $NV_VERSION"

tar -xzf "$ARCHIVE" -C "$NV_WORKDIR"

OLDPWD=$(pwd)
cd "$(find "$NV_WORKDIR" -mindepth 1 -maxdepth 1 -type d | head -1)"

# Apply nvidia hackpatches if we have them
for patch in "${OLDPWD}"/patches-nvidia/*.patch; do patch -p1 < "$patch"; done

if [ "${TARGET_ARCH_STANDARD}" = "aarch64" ]; then
	CROSS_ENV="env CC=aarch64-linux-gnu-gcc LD=aarch64-linux-gnu-ld AR=aarch64-linux-gnu-ar CXX=aarch64-linux-gnu-g++ OBJCOPY=aarch64-linux-gnu-objcopy"
else
	CROSS_ENV=""
fi

${CROSS_ENV} make -C . TARGET_ARCH="${TARGET_ARCH_STANDARD}" SYSSRC="${KERNEL_SRC}" SYSOUT="${KERNEL_OBJ}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}"  modules

echo "Nvidia $NV_VERSION build done"

${CROSS_ENV} make -C . TARGET_ARCH="${TARGET_ARCH_STANDARD}" SYSSRC="${KERNEL_SRC}" SYSOUT="${KERNEL_OBJ}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}" INSTALL_MOD_PATH="${MODULES_INSTALL_PATH}" modules_install

echo "Nvidia $NV_VERSION install done"

cd "$OLDPWD"
