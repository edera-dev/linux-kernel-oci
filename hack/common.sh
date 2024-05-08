#!/bin/sh
set -e

REAL_SCRIPT="$(realpath "${0}")"
cd "$(dirname "${REAL_SCRIPT}")/.."
KERNEL_DIR="$(realpath "${PWD}")"

cd "${KERNEL_DIR}"

TARGET_ARCH_STANDARD="$(./hack/build/arch.sh)"

if [ "${TARGET_ARCH_STANDARD}" = "arm64" ]
then
  TARGET_ARCH_STANDARD="aarch64"
fi

TARGET_ARCH_KERNEL="$(./hack/build/arch.sh)"
C_TARGET="$(./hack/build/target.sh)"
IS_CROSS_COMPILE="$(./hack/build/cross-compile.sh)"

if [ "${IS_CROSS_COMPILE}" = "1" ]
then
  CROSS_COMPILE_MAKE="CROSS_COMPILE=${C_TARGET}-"
else
  CROSS_COMPILE_MAKE="CROSS_COMPILE="
fi

if [ -z "${KERNEL_VERSION_CONFIG}" ]
then
  KERNEL_VERSION_CONFIG="stable"
fi

KERNEL_VERSION_CONFIG_FILE="${KERNEL_DIR}/versions/${KERNEL_VERSION_CONFIG}"
if [ ! -f "${KERNEL_VERSION_CONFIG_FILE}" ]
then
  echo "ERROR: version config '${KERNEL_VERSION_CONFIG}' does not exist!" > /dev/stderr
  exit 1
fi
. "${KERNEL_VERSION_CONFIG_FILE}"

KERNEL_SRC="${KERNEL_DIR}/build/linux-${KERNEL_VERSION}-${TARGET_ARCH_STANDARD}"

if [ -z "${KERNEL_BUILD_JOBS}" ]
then
  KERNEL_BUILD_JOBS="$(nproc)"
fi

if [ ! -f "${KERNEL_SRC}/Makefile" ]
then
  rm -rf "${KERNEL_SRC}"
  mkdir -p "${KERNEL_SRC}"
  curl --progress-bar -L -o "${KERNEL_SRC}.txz" "${KERNEL_SRC_URL}"
  tar xf "${KERNEL_SRC}.txz" --strip-components 1 -C "${KERNEL_SRC}"
  rm "${KERNEL_SRC}.txz"
fi

OUTPUT_DIR="${KERNEL_DIR}/target"
mkdir -p "${OUTPUT_DIR}"

KERNEL_CONFIG_FILE="${KERNEL_DIR}/configs/krata-${TARGET_ARCH_STANDARD}.config"

if [ ! -f "${KERNEL_CONFIG_FILE}" ]
then
  echo "ERROR: kernel config file not found for ${TARGET_ARCH_STANDARD}" > /dev/stderr
  exit 1
fi

cp "${KERNEL_CONFIG_FILE}" "${KERNEL_SRC}/.config"
make -C "${KERNEL_SRC}" ARCH="${TARGET_ARCH_KERNEL}" "${CROSS_COMPILE_MAKE}" olddefconfig

# shellcheck disable=SC2034
IMAGE_TARGET="bzImage"

if [ "${TARGET_ARCH_STANDARD}" = "x86_64" ]
then
  # shellcheck disable=SC2034
  IMAGE_TARGET="bzImage"
elif [ "${TARGET_ARCH_STANDARD}" = "aarch64" ]
then
  # shellcheck disable=SC2034
  IMAGE_TARGET="Image.gz"
fi

# shellcheck disable=SC2034
MODULES_INSTALL_PATH="${OUTPUT_DIR}/modules-install"
# shellcheck disable=SC2034
ADDONS_OUTPUT_PATH="${OUTPUT_DIR}/addons"
# shellcheck disable=SC2034
MODULES_OUTPUT_PATH="${ADDONS_OUTPUT_PATH}/modules"
# shellcheck disable=SC2034
ADDONS_SQUASHFS_PATH="${OUTPUT_DIR}/addons.squashfs"
