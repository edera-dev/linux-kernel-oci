#!/bin/sh
set -e

cd "$(dirname "${0}")/../.."

mkdir -p target
DATA_TMP_DIR="$(mktemp -d)"
trap 'rm -rf ${DATA_TMP_DIR}' EXIT
KERNEL_RELEASES_JSON="${DATA_TMP_DIR}/releases.json"
curl -sfL https://www.kernel.org/releases.json > "${KERNEL_RELEASES_JSON}"

major_versions() {
  rsync --list-only --out-format='%n' "rsync://rsync.kernel.org/pub/linux/kernel/" | \
    awk '{ print $5 }' | grep -E '^v(.*)x$' | awk -F '.x' '{print $1}' | sed 's/^v//'
}

release_versions() {
  rsync --list-only --out-format='%n' "rsync://rsync.kernel.org/pub/linux/kernel/v${1}.x/" | \
    awk '{print $5}' | grep '.xz$' | grep "linux-" | awk -F '-' '{print $2}' | \
    awk -F '.tar' '{print $1}' | sort --version-sort
}

major_versions | while read -r MAJOR_VERSION
do
  release_versions "${MAJOR_VERSION}"
done | sort --version-sort > "${DATA_TMP_DIR}/all-versions"

rm -rf "target/matrix.json"
python3 "$(dirname "${0}")/generate-backbuild-matrix.py" "${DATA_TMP_DIR}" "target/matrix.json"
