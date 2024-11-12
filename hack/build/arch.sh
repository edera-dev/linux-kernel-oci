#!/bin/sh
set -e

TOOLS_DIR="$(dirname "${0}")"

C_TARGET="$("${TOOLS_DIR}/target.sh")"
TARGET_ARCH="$(echo "${C_TARGET}" | awk -F '-' '{print $1}')"

if [ "${TARGET_ARCH}" = "aarch64" ]; then
	TARGET_ARCH="arm64"
fi

echo "${TARGET_ARCH}"
