#!/bin/sh
set -e

# shellcheck disable=SC2034
FIRMWARE_OUTPUT_PATH="${ADDONS_OUTPUT_PATH}/firmware"

# Any firmwares (if any needed) that should ultimately end up in the squashfs
# should be sitting at this location when this script finishes.
# (will go in ${ADDONS_PATH}/firmware, siblings with `${ADDONS_PATH}/modules`)
mkdir -p "${FIRMWARE_OUTPUT_PATH}"

if [ -n "${FIRMWARE_SIG_URL}" ]; then
	# Getting the pubkey from the signature is slightly stupid, ideally we should maintain
	# a list of valid keys out-of-band, this is best-effort.
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


# Note that this assumes the archive is a .tar file, and has already been validated elsewhere.
if [ -n "${FIRMWARE_URL}" ]; then
	echo "untarring firmware at $FIRMWARE_URL"
	tar -xf "${FIRMWARE_URL}" -C "${FIRMWARE_OUTPUT_PATH}" --strip-components=1
	# For amdgpu zone kernel, we only want the amdgpu firmwares, so remove the rest to keep the addons small
	if [ "${KERNEL_FLAVOR}" = "zone-amdgpu" ]; then
		OLDDIR=$PWD
		cd "${FIRMWARE_OUTPUT_PATH}"
		find . -maxdepth 1 ! -name 'amdgpu' ! -name "." -exec rm -rf {} +
		# Compress firmwares on-disk
		# As of 6.x kernels the kconfig explicitly says you must use crc32 or none, not the default crc64.
		xz -C crc32 amdgpu/*
		cd "${OLDDIR}"
	fi
fi

# For nvidia kernel, firmware is distributed via their out-of-tree .run userspace
# package, which we need to fetch and extract.
# TODO(BML) fix arm64 builds
if [ "${KERNEL_FLAVOR}" = "zone-nvidiagpu" ] && [ "${TARGET_ARCH_STANDARD}" = "x86_64" ]; then
	# Check that we already set NV_VERSION when building the out-of-tree kmod,
	# naturally, we must fetch the matching runtime package.
	if [ -z "${NV_VERSION}" ]; then
		echo "ERROR: flavor is zone-nvidiagpu but no NV_VERSION is set"
		exit 1
	fi

	OLDDIR=$PWD

	# TBH it's probably the same firmware regardless
	if [ "${TARGET_ARCH_STANDARD}" = "aarch64" ]; then
		NV_RUN_FILE="NVIDIA-Linux-aarch64-${NV_VERSION}.run"
		NV_RUN_URL="https://us.download.nvidia.com/XFree86/aarch64/${NV_VERSION}/${NV_RUN_FILE}"
	elif [ "${TARGET_ARCH_STANDARD}" = "x86_64" ]; then
		NV_RUN_FILE="NVIDIA-Linux-x86_64-${NV_VERSION}.run"
		NV_RUN_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${NV_VERSION}/${NV_RUN_FILE}"
	fi

	NV_EXTRACT_PATH="$(mktemp -d)/extracted-${NV_VERSION}"
	mkdir -p "$NV_EXTRACT_PATH"

	echo "Downloading NVIDIA runtime package for driver ${NV_VERSION} from: $NV_RUN_URL"
	curl --retry 5 --retry-delay 2 --retry-max-time 30 --retry-all-errors -L -o "$NV_EXTRACT_PATH/$NV_RUN_FILE" "$NV_RUN_URL"
	chmod +x "$NV_EXTRACT_PATH/$NV_RUN_FILE"
	"$NV_EXTRACT_PATH/$NV_RUN_FILE" -x --target "$NV_EXTRACT_PATH/out"
	# Compress firmwares on-disk
	# As of 6.x kernels the kconfig explicitly says you must use crc32 or none, not the default crc64.
	xz -C crc32 "$NV_EXTRACT_PATH"/out/firmware/*
	ls -lah "$NV_EXTRACT_PATH/out/firmware/"
	NV_FW_PATH="${FIRMWARE_OUTPUT_PATH}/nvidia/$NV_VERSION"
	mkdir -p "${NV_FW_PATH}"
	cp "$NV_EXTRACT_PATH"/out/firmware/*.xz "${NV_FW_PATH}"
	cd "${OLDDIR}"
fi
