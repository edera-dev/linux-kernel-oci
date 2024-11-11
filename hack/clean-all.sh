#!/bin/sh
set -e

REAL_SCRIPT="$(realpath "${0}")"
cd "$(dirname "${REAL_SCRIPT}")/.."
KERNEL_DIR="$(realpath "${PWD}")"

cd "${KERNEL_DIR}"
rm -rf obj src target
