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

# Kernel sources come from Edera's downstream tree (see config.yaml); there is
# no upstream fallback to derive a URL from, so this must be supplied. The
# matrix hands it to us as an immutable commit archive; the Dockerfile stages
# that into the build container as a local file.
if [ -z "${KERNEL_SRC_URL}" ]; then
	echo "ERROR: KERNEL_SRC_URL must be specified." >&2
	exit 1
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

# KERNEL_SRC_URL is one of:
#   - a path to a local source archive (what CI uses: the Dockerfile ADDs the
#     commit archive into the build container, and the compile step points here
#     at that file),
#   - an http(s) URL to a source archive,
#   - "git::<url>[::<ref>]", which clones <ref> directly. Handy locally for
#     building a work-in-progress branch without pushing it anywhere.
#
# No patches are applied either way: every Edera change is a commit on the
# branch being built, so the tree that lands here is the tree that gets
# compiled.
if [ ! -f "${KERNEL_SRC}/Makefile" ]; then
	rm -rf "${KERNEL_SRC}"
	mkdir -p "${KERNEL_SRC}"
	if [ -f "${KERNEL_SRC_URL}" ]; then
		mv "${KERNEL_SRC_URL}" "${KERNEL_SRC}.tar"
		tar xf "${KERNEL_SRC}.tar" --strip-components 1 -C "${KERNEL_SRC}"
		rm "${KERNEL_SRC}.tar"
	elif echo "${KERNEL_SRC_URL}" | grep -E '^git::' >/dev/null; then
		KERNEL_GIT_URL="$(echo "${KERNEL_SRC_URL}" | awk -F '::' '{print $2}')"
		KERNEL_GIT_REF="$(echo "${KERNEL_SRC_URL}" | awk -F '::' '{print $3}')"
		if [ -z "${KERNEL_GIT_REF}" ]; then
			KERNEL_GIT_REF="master"
		fi
		git clone --depth 1 "${KERNEL_GIT_URL}" -b "${KERNEL_GIT_REF}" "${KERNEL_SRC}"
	else
		curl --progress-bar -Lf -o "${KERNEL_SRC}.tar" "${KERNEL_SRC_URL}"
		tar xf "${KERNEL_SRC}.tar" --strip-components 1 -C "${KERNEL_SRC}"
		rm "${KERNEL_SRC}.tar"
	fi
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

	MAKE_CONFIG_FRAGMENTS="${KERNEL_FLAVOR}.config"
	;;
esac

# shellcheck disable=SC2086
make -C "${KERNEL_SRC}" O="${KERNEL_OBJ}" ARCH="${TARGET_ARCH_KERNEL}" "${CROSS_COMPILE_MAKE}" olddefconfig $MAKE_CONFIG_FRAGMENTS

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

# the trees we build (an -rc in particular) routinely carry warnings that
# upstream has not swept up yet; this keeps them logged without failing the
# build.
export EXTRA_CFLAGS="-Wno-error"
