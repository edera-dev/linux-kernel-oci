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

if [ -z "${KERNEL_VERSION}" ]
then
  echo "ERROR: KERNEL_VERSION must be specified." > /dev/stderr
  exit 1
fi

if [ -z "${KERNEL_SRC_URL}" ]
then
  echo "ERROR: KERNEL_SRC_URL must be specified." > /dev/stderr
  exit 1
fi

if [ -z "${KERNEL_FLAVOR}" ]
then
  KERNEL_FLAVOR="standard"
fi

KERNEL_SRC="${KERNEL_DIR}/src/linux-${KERNEL_VERSION}-${TARGET_ARCH_STANDARD}"
KERNEL_OBJ="${KERNEL_DIR}/obj/linux-${KERNEL_VERSION}-${TARGET_ARCH_STANDARD}"

if [ -z "${KERNEL_BUILD_JOBS}" ]
then
  KERNEL_BUILD_JOBS="$(nproc)"
fi

# In the case of a stable release, e.g. 6.10.7, this becomes 6.10.
MAINLINE_VERSION="${KERNEL_VERSION%.*}"
# In the case of a mainline release, e.g. 6.10, this will collapse to
# 6 -> 6.  In that case, ${KERNEL_VERSION} is the mainline version.
if [ "${MAINLINE_VERSION}" = "${MAINLINE_VERSION%.*}" ]
then
  MAINLINE_VERSION="${KERNEL_VERSION}"
fi

BASE_SERIES_FILE="${KERNEL_DIR}/patches/${MAINLINE_VERSION}/base/series"
SERIES_FILE="${KERNEL_DIR}/patches/${MAINLINE_VERSION}/${KERNEL_FLAVOR}/series"

if [ ! -f "${KERNEL_SRC}/Makefile" ]
then
  rm -rf "${KERNEL_SRC}"
  mkdir -p "${KERNEL_SRC}"
  curl --progress-bar -L -o "${KERNEL_SRC}.txz" "${KERNEL_SRC_URL}"
  tar xf "${KERNEL_SRC}.txz" --strip-components 1 -C "${KERNEL_SRC}"
  rm "${KERNEL_SRC}.txz"

  if [ -f "${BASE_SERIES_FILE}" ]
  then
    cd "${KERNEL_SRC}"
    while read patch; do
      patch -p1 < "${KERNEL_DIR}/patches/${MAINLINE_VERSION}/base/$patch"
    done < "${BASE_SERIES_FILE}"
    cd "${KERNEL_DIR}"
  fi

  if [ -f "${SERIES_FILE}" ]
  then
    cd "${KERNEL_SRC}"
    while read patch; do
      patch -p1 < "${KERNEL_DIR}/patches/${MAINLINE_VERSION}/${KERNEL_FLAVOR}/$patch"
    done < "${SERIES_FILE}"
    cd "${KERNEL_DIR}"
  fi
fi

OUTPUT_DIR="${KERNEL_DIR}/target"
mkdir -p "${OUTPUT_DIR}"

KERNEL_CONFIG_FILE="${KERNEL_DIR}/configs/${KERNEL_FLAVOR}-${TARGET_ARCH_STANDARD}.config"

if [ ! -f "${KERNEL_CONFIG_FILE}" ]
then
  echo "ERROR: kernel config file not found for ${TARGET_ARCH_STANDARD}" > /dev/stderr
  exit 1
fi

cp "${KERNEL_CONFIG_FILE}" "${KERNEL_SRC}/.config"
make -C "${KERNEL_SRC}" O="${KERNEL_OBJ}" ARCH="${TARGET_ARCH_KERNEL}" "${CROSS_COMPILE_MAKE}" olddefconfig

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
# shellcheck disable=SC2034
METADATA_PATH="${OUTPUT_DIR}/metadata"
# shellcheck disable=SC2034
CONFIG_GZ_PATH="${OUTPUT_DIR}/config.gz"
# shellcheck disable=SC2034
SDK_PATH="${OUTPUT_DIR}/sdk.tar.gz"
