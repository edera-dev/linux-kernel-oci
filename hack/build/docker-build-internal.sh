#!/bin/sh
set -e

REAL_SCRIPT="$(realpath "${0}")"
cd "$(dirname "${REAL_SCRIPT}")/../.."

if [ -z "${KERNEL_VERSION}" ] || [ -z "${KERNEL_FLAVOR}" ]; then
	echo "Usage: KERNEL_VERSION=version KERNEL_FLAVOR=flavor build" >&2
	exit 1
fi

./hack/build/build.sh
