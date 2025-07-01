#!/bin/sh
set -e

# shellcheck disable=SC2034
FIRMWARE_OUTPUT_PATH="${ADDONS_OUTPUT_PATH}/firmware"

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

# Firmware handling (will go in ${ADDONS_PATH}/firmware, siblings with `${ADDONS_PATH}/modules`)
# Note that this assumes the archive is a .tar file, and has already been validated elsewhere.
if [ -n "${FIRMWARE_URL}" ]; then
	mkdir -p "${FIRMWARE_OUTPUT_PATH}"
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
