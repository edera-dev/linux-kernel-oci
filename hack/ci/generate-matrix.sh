#!/bin/sh
set -e

cd "$(dirname "${0}")/../.."

mkdir -p target
DATA_TMP_DIR="$(mktemp -d)"
trap "rm -rf ${DATA_TMP_DIR}" EXIT
KERNEL_RELEASES_JSON="${DATA_TMP_DIR}/releases.json"
curl -sfL https://www.kernel.org/releases.json > "${KERNEL_RELEASES_JSON}"
rm -rf "target/matrix.json"
python3 "$(dirname "${0}")/generate-matrix.py" "${DATA_TMP_DIR}" "target/matrix.json"
