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

# Getting the pubkey from the signature is slightly stupid, ideally we should maintain
# a list of valid keys out-of-band, this is best-effort.
if [ -n "${FIRMWARE_SIG_URL}" ]; then
	echo "Found firmware signature $FIRMWARE_SIG_URL, attempting validation"

	# Check if FIRMWARE_URL exists and is a regular file
	if [ ! -f "$FIRMWARE_URL" ]; then
		echo "ERROR: $FIRMWARE_URL does not exist or is not a regular file"
		echo "ERROR: If this was intentional, consider unsetting '$FIRMWARE_SIG_URL'"
		exit 1
	fi

	KEY_INFO=$(gpg --verify "$FIRMWARE_SIG_URL" "$FIRMWARE_URL" 2>&1) || true
	KEY_ID=$(echo "$KEY_INFO" | grep -E "using .* key|key ID" | grep -oE "[A-F0-9]{40}|[A-F0-9]{16,}")
	gpg --recv-key "$KEY_ID"
	unxz "$FIRMWARE_URL"
	# We've uncompressed it, update the env var so later stuff points at the right file
	FIRMWARE_URL="${FIRMWARE_URL%.xz}"
	gpg --verify "$FIRMWARE_SIG_URL" || { echo "ERROR: signature ${FIRMWARE_SIG_URL} cannot validate ${FIRMWARE_URL}"; exit 1; }
else
	echo "No firmware signature defined, no validation will be performed"
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
	KERNEL_SRC_IS_TAR="1"
	if [ ! -f "${KERNEL_SRC_URL}" ]; then
		if echo "${KERNEL_SRC_URL}" | grep -E '^git::' >/dev/null; then
			KERNEL_SRC_IS_TAR="0"
			KERNEL_GIT_URL="$(echo "${KERNEL_SRC_URL}" | awk -F '::' '{print $2}')"
			KERNEL_GIT_REF="$(echo "${KERNEL_SRC_URL}" | awk -F '::' '{print $3}')"
			if [ -z "${KERNEL_GIT_REF}" ]; then
				KERNEL_GIT_REF="master"
			fi
			git clone "${KERNEL_GIT_URL}" -b "${KERNEL_GIT_REF}" "${KERNEL_SRC}"
		else
			curl --progress-bar -Lf -o "${KERNEL_SRC}.txz" "${KERNEL_SRC_URL}"
		fi
	else
		mv "${KERNEL_SRC_URL}" "${KERNEL_SRC}.txz"
	fi

	if [ "${KERNEL_SRC_IS_TAR}" = "1" ]; then
		tar xf "${KERNEL_SRC}.txz" --strip-components 1 -C "${KERNEL_SRC}"
		rm "${KERNEL_SRC}.txz"
	fi

	python3 "hack/build/patchlist.py" "${KERNEL_VERSION}" "${KERNEL_FLAVOR}" | while read -r PATCH_NAME; do
		cd "${KERNEL_SRC}"
		if [ "${KERNEL_SRC_IS_TAR}" = "1" ]; then
			patch -p1 <"${KERNEL_DIR}/${PATCH_NAME}"
		else
			git apply "${KERNEL_DIR}/${PATCH_NAME}"
		fi
		cd "${KERNEL_DIR}"
	done
	cd "${KERNEL_DIR}"
fi

OUTPUT_DIR="${KERNEL_DIR}/target"
mkdir -p "${OUTPUT_DIR}"

mkdir -p "${KERNEL_OBJ}"

KERNEL_ARCH_STANDARD=$TARGET_ARCH_STANDARD

# HACK: kconfig paths use different arch keywords, so we have to get cute and munge
case "${TARGET_ARCH_STANDARD}" in
	x86_64)
		KERNEL_ARCH_STANDARD="x86"
		;;
	aarch64)
		KERNEL_ARCH_STANDARD="arm64"
		;;
	*)
		KERNEL_ARCH_STANDARD="${TARGET_ARCH_STANDARD}"
		;;
esac

KCONFIG_FRAGMENT_DEST="${KERNEL_SRC}/arch/${KERNEL_ARCH_STANDARD}/configs/"

# Copy out our custom kconfig - if we are building for a <flavor>-<variant>, merge the variant fragment with the flavor baseconfig
# by copying the fragment into the kernel src tree and letting the kernel's `make` merge them
case "${KERNEL_FLAVOR}" in
  *-*)
	# Looks like we are dealing with <flavor>-<variant>.config, versus <flavor>.config, so we have 2 fragments
	FLAVOR=$(echo "${KERNEL_FLAVOR}" | cut -d'-' -f1)
	VARIANT=$(echo "${KERNEL_FLAVOR}" | cut -d'-' -f2)

	BASE_FLAVOR_CONFIG="${KERNEL_DIR}/configs/${TARGET_ARCH_STANDARD}/${FLAVOR}.config"
	VARIANT_FRAGMENT_CONFIG="${KERNEL_DIR}/configs/${TARGET_ARCH_STANDARD}/${FLAVOR}-${VARIANT}.fragment.config"

	if [ ! -f "${BASE_FLAVOR_CONFIG}" ]; then
		echo "ERROR: kernel flavor base config file not found for ${TARGET_ARCH_STANDARD}" >&2
		exit 1
	fi

	if [ ! -f "${VARIANT_FRAGMENT_CONFIG}" ]; then
		echo "ERROR: kernel flavor variant fragment config file not found for ${TARGET_ARCH_STANDARD}" >&2
		exit 1
	fi
	# If you drop extra config fragments into arch/<arch>/configs, the kernel's make will merge them for you
	# with the default config into $KERNEL_OBJ/.config
	cp "${BASE_FLAVOR_CONFIG}" "${KCONFIG_FRAGMENT_DEST}"

	cp "${VARIANT_FRAGMENT_CONFIG}" "${KCONFIG_FRAGMENT_DEST}"

	# Add the fragment we copied out to the make args
	# NOTE `make` craps the bed if you pass a leading space in front of the fragment here.
	MAKE_CONFIG_FRAGMENTS="${FLAVOR}.config ${FLAVOR}-${VARIANT}.fragment.config"
	;;
  *)
	# Looks like we are dealing with just one <flavor>.config fragment
	BASE_FLAVOR_CONFIG="${KERNEL_DIR}/configs/${TARGET_ARCH_STANDARD}/${KERNEL_FLAVOR}.config"

	if [ ! -f "${BASE_FLAVOR_CONFIG}" ]; then
		echo "ERROR: kernel flavor base config file not found for ${TARGET_ARCH_STANDARD}: ${BASE_FLAVOR_CONFIG}" >&2
		exit 1
	fi

	# If you drop extra config fragments into arch/<arch>/configs, the kernel's make will merge them for you
	# with the default config into $KERNEL_OBJ/.config
	cp "${BASE_FLAVOR_CONFIG}" "${KCONFIG_FRAGMENT_DEST}"

	MAKE_CONFIG_FRAGMENTS="${FLAVOR}.config"
	;;
esac

make -C "${KERNEL_SRC}" O="${KERNEL_OBJ}" ARCH="${TARGET_ARCH_KERNEL}" "${CROSS_COMPILE_MAKE}" olddefconfig "${MAKE_CONFIG_FRAGMENTS}"

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
FIRMWARE_OUTPUT_PATH="${ADDONS_OUTPUT_PATH}/firmware"
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
