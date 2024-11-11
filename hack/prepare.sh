#!/bin/sh
set -e

REAL_SCRIPT="$(realpath "${0}")"
cd "$(dirname "${REAL_SCRIPT}")/.."
KERNEL_DIR="$(realpath "${PWD}")"

# shellcheck source-path=SCRIPTDIR source=common.sh
. "${KERNEL_DIR}/hack/common.sh"
