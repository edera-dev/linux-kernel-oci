#!/bin/sh
set -e

if [ "${KERNEL_FLAVOR}" != "zone-nvidiagpu" ]; then
	return
fi

NVIDIA_KMOD_REPO=https://github.com/NVIDIA/open-gpu-kernel-modules
NVIDIA_KMOD_REPO_BRANCH=main
echo "Cloning nvidia out-of-tree module repo"

git clone "${NVIDIA_KMOD_REPO} -b ${NVIDIA_KMOD_REPO_BRANCH}" nvidia-kmod

cd nvidia-kmod

# make -C "${KERNEL_OBJ}" TARGET_ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}" "${IMAGE_TARGET}" modules
make -C "${KERNEL_OBJ}" TARGET_ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}"  modules

make -C "${KERNEL_OBJ}" TARGET_ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}" INSTALL_MOD_PATH="${MODULES_INSTALL_PATH}" modules_install
# REAL_SCRIPT="$(realpath "${0}")"
# cd "$(dirname "${REAL_SCRIPT}")/../.."
# KERNEL_DIR="$(realpath "${PWD}")"

# cd "${KERNEL_DIR}"
