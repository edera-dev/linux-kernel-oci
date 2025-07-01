#!/bin/sh
set -e

REAL_SCRIPT="$(realpath "${0}")"
cd "$(dirname "${REAL_SCRIPT}")/../.."
KERNEL_DIR="$(realpath "${PWD}")"

NV_CLONE_PATH=/tmp/nvidia-modules

git clone git@github.com:NVIDIA/open-gpu-kernel-modules.git -b main $NV_CLONE_PATH


make -C "${KERNEL_OBJ}" ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}" "${IMAGE_TARGET}" modules

rm -rf "${MODULES_INSTALL_PATH}"
rm -rf "${ADDONS_OUTPUT_PATH}"
rm -rf "${ADDONS_SQUASHFS_PATH}"
rm -rf "${METADATA_PATH}"

make -C "${KERNEL_OBJ}" ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}" INSTALL_MOD_PATH="${MODULES_INSTALL_PATH}" modules_install
KERNEL_MODULES_VER="$(ls "${MODULES_INSTALL_PATH}/lib/modules")"

. "${KERNEL_DIR}/hack/build/nvidiagpu-common.sh"

mkdir -p "${ADDONS_OUTPUT_PATH}"
