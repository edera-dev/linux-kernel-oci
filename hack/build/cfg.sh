#!/bin/sh
set -e

CMD="${1}"
if [ -z "${CMD}" ]; then
	CMD="nconfig"
fi

REAL_SCRIPT="$(realpath "${0}")"
cd "$(dirname "${REAL_SCRIPT}")/../.."
KERNEL_DIR="$(realpath "${PWD}")"

# shellcheck source-path=SCRIPTDIR source=common.sh
. "${KERNEL_DIR}/hack/build/common.sh"

rm -rf "${MODULES_INSTALL_PATH}"
rm -rf "${ADDONS_OUTPUT_PATH}"
rm -rf "${ADDONS_SQUASHFS_PATH}"

make -C "${KERNEL_SRC}" O="${KERNEL_OBJ}" ARCH="${TARGET_ARCH_KERNEL}" "${CROSS_COMPILE_MAKE}" INSTALL_MOD_PATH="${MODULES_INSTALL_PATH}" "${CMD}"
cp "${KERNEL_OBJ}/.config" "${KERNEL_CONFIG_FILE}"
