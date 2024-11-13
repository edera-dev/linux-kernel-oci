#!/bin/sh
set -e

REAL_SCRIPT="$(realpath "${0}")"
cd "$(dirname "${REAL_SCRIPT}")/../.."
KERNEL_DIR="$(realpath "${PWD}")"

cd "${KERNEL_DIR}"

TARGET_ARCH_STANDARD="$(./hack/build/arch.sh)"

if [ "${TARGET_ARCH_STANDARD}" = "arm64" ]; then
	TARGET_ARCH_STANDARD="aarch64"
fi

TARGET_ARCH_KERNEL="$(./hack/build/arch.sh)"
C_TARGET="$(./hack/build/target.sh)"
IS_CROSS_COMPILE="$(./hack/build/cross-compile.sh)"

if [ "${IS_CROSS_COMPILE}" = "1" ]; then
	CROSS_COMPILE_MAKE="CROSS_COMPILE=${C_TARGET}-"
else
	CROSS_COMPILE_MAKE="CROSS_COMPILE="
fi

if [ -z "${KERNEL_VERSION}" ]; then
	echo "ERROR: KERNEL_VERSION must be specified." >&2
	exit 1
fi

if [ -z "${KERNEL_SRC_URL}" ]; then
	KERNEL_SRC_URL="$(./hack/build/cdn-url.sh "${KERNEL_VERSION}")"
fi

if [ -z "${KERNEL_FLAVOR}" ]; then
	KERNEL_FLAVOR="zone"
fi

KERNEL_SRC="${KERNEL_DIR}/src/linux-${KERNEL_VERSION}-${TARGET_ARCH_STANDARD}"
KERNEL_OBJ="${KERNEL_DIR}/obj/linux-${KERNEL_VERSION}-${TARGET_ARCH_STANDARD}"

if [ -z "${KERNEL_BUILD_JOBS}" ]; then
	KERNEL_BUILD_JOBS="$(nproc)"
	KERNEL_BUILD_JOBS="$((KERNEL_BUILD_JOBS + 1))"
fi

# In the case of a stable release, e.g. 6.10.7, this becomes 6.10.
MAINLINE_VERSION="${KERNEL_VERSION%.*}"
# In the case of a mainline release, e.g. 6.10, this will collapse to
# 6 -> 6.  In that case, ${KERNEL_VERSION} is the mainline version.
if [ "${MAINLINE_VERSION}" = "${MAINLINE_VERSION%.*}" ]; then
	MAINLINE_VERSION="${KERNEL_VERSION}"
fi

if [ ! -f "${KERNEL_SRC}/Makefile" ]; then
	rm -rf "${KERNEL_SRC}"
	mkdir -p "${KERNEL_SRC}"
	if [ ! -f "${KERNEL_SRC_URL}" ]; then
		curl --progress-bar -Lf -o "${KERNEL_SRC}.txz" "${KERNEL_SRC_URL}"
	else
		mv "${KERNEL_SRC_URL}" "${KERNEL_SRC}.txz"
	fi
	tar xf "${KERNEL_SRC}.txz" --strip-components 1 -C "${KERNEL_SRC}"
	rm "${KERNEL_SRC}.txz"

	python3 "hack/build/patchlist.py" "${KERNEL_VERSION}" "${KERNEL_FLAVOR}" | while read -r PATCH_NAME; do
		cd "${KERNEL_SRC}"
		patch -p1 <"${KERNEL_DIR}/${PATCH_NAME}"
		cd "${KERNEL_DIR}"
	done
	cd "${KERNEL_DIR}"
fi

OUTPUT_DIR="${KERNEL_DIR}/target"
mkdir -p "${OUTPUT_DIR}"

KERNEL_CONFIG_FILE="${KERNEL_DIR}/configs/${TARGET_ARCH_STANDARD}/${KERNEL_FLAVOR}.config"

if [ ! -f "${KERNEL_CONFIG_FILE}" ]; then
	echo "ERROR: kernel config file not found for ${TARGET_ARCH_STANDARD}" >&2
	exit 1
fi

mkdir -p "${KERNEL_OBJ}"
cp "${KERNEL_CONFIG_FILE}" "${KERNEL_OBJ}/.config"
make -C "${KERNEL_SRC}" O="${KERNEL_OBJ}" ARCH="${TARGET_ARCH_KERNEL}" "${CROSS_COMPILE_MAKE}" olddefconfig

# shellcheck disable=SC2034
IMAGE_TARGET="bzImage"

if [ "${TARGET_ARCH_STANDARD}" = "x86_64" ]; then
	# shellcheck disable=SC2034
	IMAGE_TARGET="bzImage"
elif [ "${TARGET_ARCH_STANDARD}" = "aarch64" ]; then
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

# we often build older kernels that have warnings
# this will ensure they are logged but do not
# prevent building of the kernel.
export EXTRA_CFLAGS="-Wno-error"
