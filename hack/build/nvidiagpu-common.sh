#!/bin/sh
set -e

if [ "${KERNEL_FLAVOR}" != "zone-nvidiagpu" ]; then
	return
fi

NV_KMOD_REPO=https://github.com/NVIDIA/open-gpu-kernel-modules
NV_KMOD_REPO_BRANCH=main
NV_CLONE_PATH=/tmp/nvidia-modules
echo "Cloning nvidia out-of-tree module repo"

git clone "${NV_KMOD_REPO} -b ${NV_KMOD_REPO_BRANCH}" ${NV_CLONE_PATH}

cd $NV_CLONE_PATH

# make SYSSRC=~/Source/edera-dev/linux-kernel-oci/linux-6.14.6 SYSOUT=/home/bleggett/Source/edera-dev/linux-kernel-oci/obj INSTALL_MOD_PATH=/home/bleggett/Source/edera-dev/linux-kernel-oci/obj modules_instal
#
# make -C "${KERNEL_OBJ}" TARGET_ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}" "${IMAGE_TARGET}" modules
make -C "${KERNEL_OBJ}" TARGET_ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}"  modules

make -C "${KERNEL_OBJ}" TARGET_ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}" INSTALL_MOD_PATH="${MODULES_INSTALL_PATH}" modules_install
# REAL_SCRIPT="$(realpath "${0}")"
# cd "$(dirname "${REAL_SCRIPT}")/../.."
# KERNEL_DIR="$(realpath "${PWD}")"

# cd "${KERNEL_DIR}"
