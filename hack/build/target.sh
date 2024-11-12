#!/bin/sh
set -e

if [ -z "${TARGET_ARCH}" ]; then
	TARGET_ARCH="$(uname -m)"
fi

# Docker buildx TARGETPLATFORM support
if [ -n "${TARGETPLATFORM}" ]; then
	TARGET_OS="$(echo "${TARGETPLATFORM}" | awk -F '/' '{print $1}')"
	if [ "${TARGET_OS}" != "linux" ]; then
		echo "ERROR: Docker Platform support requires the OS part of the platform (${TARGETPLATFORM}) to be linux" >&2
		exit 1
	fi
	TARGET_ARCH="$(echo "${TARGETPLATFORM}" | awk -F '/' '{print $2}')"
fi

if [ "${TARGET_ARCH}" = "arm64" ]; then
	TARGET_ARCH="aarch64"
fi

if [ "${TARGET_ARCH}" = "amd64" ]; then
	TARGET_ARCH="x86_64"
fi

if [ -z "${TARGET_TOOLCHAIN_TYPE}" ]; then
	TARGET_TOOLCHAIN_TYPE="linux-gnu"
fi

[ "${TARGET_ARCH}" = "x86_64" ] && C_TARGET="x86_64-${TARGET_TOOLCHAIN_TYPE}"
[ "${TARGET_ARCH}" = "aarch64" ] && C_TARGET="aarch64-${TARGET_TOOLCHAIN_TYPE}"

if [ -z "${C_TARGET}" ]; then
	echo "ERROR: Unable to determine C_TARGET from arch '${TARGET_ARCH}', your architecture may not be supported." >&2
	exit 1
fi

echo "${C_TARGET}"
