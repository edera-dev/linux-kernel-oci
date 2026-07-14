#!/bin/sh
set -e

REAL_SCRIPT="$(realpath "${0}")"
cd "$(dirname "${REAL_SCRIPT}")/../.."

if [ -z "${KERNEL_VERSION}" ] || [ -z "${KERNEL_FLAVOR}" ]; then
	echo "Usage: KERNEL_VERSION=version KERNEL_FLAVOR=flavor build" >&2
	exit 1
fi

./hack/build/build.sh

# Surface cache effectiveness (hits vs misses, backend errors) in build logs.
# || true: this may respawn an idle-timed-out server, and a transient backend
# error there must not fail an otherwise-successful build (set -e above).
sccache --show-stats || true
