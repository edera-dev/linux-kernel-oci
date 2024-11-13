#!/bin/sh
set -e

if [ -z "${1}" ]; then
	echo "Usage: cdn-url.sh <KERNEL_VERSION>" >&2
	exit 1
fi

KERNEL_VERSION="${1}"
MAJOR_VERSION="$(echo "${KERNEL_VERSION}" | awk -F '.' '{print $1}')"
MINOR_VERSION="$(echo "${KERNEL_VERSION}" | awk -F '.' '{print $2}')"
PATCH_VERSION="$(echo "${KERNEL_VERSION}" | awk -F '.' '{print $3}')"

if [ "${PATCH_VERSION}" = "0" ]; then
	KERNEL_VERSION="${MAJOR_VERSION}.${MINOR_VERSION}"
fi

echo "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR_VERSION}.x/linux-${KERNEL_VERSION}.tar.xz"
