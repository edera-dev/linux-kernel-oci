#!/bin/bash
set -e

REAL_SCRIPT="$(realpath "${0}")"
cd "$(dirname "${REAL_SCRIPT}")/../.."
KERNEL_DIR="$(realpath "${PWD}")"

# shellcheck source-path=SCRIPTDIR source=common.sh
. "${KERNEL_DIR}/hack/build/common.sh"

make -C "${KERNEL_OBJ}" ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}" "${IMAGE_TARGET}" modules

rm -rf "${MODULES_INSTALL_PATH}"
rm -rf "${ADDONS_OUTPUT_PATH}"
rm -rf "${ADDONS_SQUASHFS_PATH}"
rm -rf "${METADATA_PATH}"

make -C "${KERNEL_OBJ}" ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}" INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="${MODULES_INSTALL_PATH}" modules_install
KERNEL_MODULES_VER="$(ls "${MODULES_INSTALL_PATH}/lib/modules")"

mkdir -p "${ADDONS_OUTPUT_PATH}"

# shellcheck source-path=SCRIPTDIR source=nvidiagpu-common.sh
. "${KERNEL_DIR}/hack/build/nvidiagpu-common.sh"

# shellcheck source-path=SCRIPTDIR source=firmware.sh
. "${KERNEL_DIR}/hack/build/firmware.sh"

mv "${MODULES_INSTALL_PATH}/lib/modules/${KERNEL_MODULES_VER}" "${MODULES_OUTPUT_PATH}"
rm -rf "${MODULES_INSTALL_PATH}"
[ -L "${MODULES_OUTPUT_PATH}/build" ] && unlink "${MODULES_OUTPUT_PATH}/build"

mksquashfs "${ADDONS_OUTPUT_PATH}" "${ADDONS_SQUASHFS_PATH}" -all-root

SQUASH_SIZE=$(stat -c %s "${ADDONS_SQUASHFS_PATH}")

# Host kernel size matters less, but we still don't want it to massively balloon all of a sudden.
case "$KERNEL_FLAVOR" in
    host*)
        if [ "${SQUASH_SIZE}" -gt 419430400 ]; then
            echo "ERROR: squashfs is >400MB in size (${SQUASH_SIZE} bytes) which is undesirable for the 'host' kernel, validate kconfig options!" >&2
            exit 1
        fi
        ;;
esac

# Generally we want to keep zone kernels small, because large kernels -> longer pull times -> increased zone cold boot times.
# We don't really care how big the host kernel is.
# Nvidia kernels have chonker firmwares, even compressed (like 200MB total size), so not much we can really do there.
case "$KERNEL_FLAVOR" in
    zone-bpf)
        # Skip the check for zone-bpf, it is allowed to be big
        ;;
    zone-nvidiagpu)
        # Firmware means this is unavoidably quite large
        ;;
    zone*)
        if [ "${SQUASH_SIZE}" -gt 52428800 ]; then
            echo "ERROR: squashfs is >50MB in size (${SQUASH_SIZE} bytes) which is undesirable for the 'zone' kernel, validate kconfig options!" >&2
            exit 1
        fi
        ;;
esac

if [ "${TARGET_ARCH_STANDARD}" = "x86_64" ]; then
	cp "${KERNEL_OBJ}/arch/x86/boot/bzImage" "${OUTPUT_DIR}/kernel"
elif [ "${TARGET_ARCH_STANDARD}" = "aarch64" ]; then
	cp "${KERNEL_OBJ}/arch/arm64/boot/Image.gz" "${OUTPUT_DIR}/kernel"
else
	echo "ERROR: unable to determine what file is the vmlinuz for ${TARGET_ARCH_STANDARD}" >&2
	exit 1
fi

rm -rf "${ADDONS_OUTPUT_PATH}"

# Prepare SDK by copying kernel config, signing key, and relevant kbuild/header files.
SDK_OUTPUT_PATH="$(mktemp -d)"

mkdir -p "${SDK_OUTPUT_PATH}"

cp -a "${KERNEL_OBJ}/.config" "${SDK_OUTPUT_PATH}/.config"
install -D -t "${SDK_OUTPUT_PATH}"/certs "${KERNEL_OBJ}"/certs/signing_key.x509 || :
make -C "${KERNEL_SRC}" O="${SDK_OUTPUT_PATH}" ARCH="${TARGET_ARCH_KERNEL}" -j"${KERNEL_BUILD_JOBS}" "${CROSS_COMPILE_MAKE}" prepare modules_prepare scripts

# Delete links to "real" kernel sources as we will copy them in place as needed.
rm "${SDK_OUTPUT_PATH}"/Makefile "${SDK_OUTPUT_PATH}"/source

PRUNE_ARCH="${TARGET_ARCH_KERNEL}"
[ "${TARGET_ARCH_KERNEL}" = "x86_64" ] && PRUNE_ARCH="x86"

cd "${KERNEL_SRC}"
find . -path './include/*' -prune \
	-o -path './scripts/*' -prune -o -type f \
	\( -name 'Makefile*' -o -name 'Kconfig*' -o -name 'Kbuild*' -o \
	-name '*.sh' -o -name '*.pl' -o -name '*.lds' -o -name 'Platform' \) \
	-print | cpio -pdm "${SDK_OUTPUT_PATH}"
cp -a scripts include "${SDK_OUTPUT_PATH}"
find "arch/${PRUNE_ARCH}" -name include -type d -print | while IFS='' read -r folder; do
	find "$folder" -type f
done | sort -u | cpio -pdm "${SDK_OUTPUT_PATH}"
cd "${KERNEL_DIR}"

install -Dm644 "${KERNEL_OBJ}"/Module.symvers "${SDK_OUTPUT_PATH}"/Module.symvers

rm -r "${SDK_OUTPUT_PATH}"/Documentation
find "${SDK_OUTPUT_PATH}" -type f -name '*.o' -printf 'Removing %P\n' -delete

for i in "${SDK_OUTPUT_PATH}"/arch/*; do
	if [ "${i##*/}" != "${PRUNE_ARCH}" ]; then
		echo "Removing unused SDK architecture headers: $i"
		rm -r "$i"
	fi
done

tar -zc -C "${SDK_OUTPUT_PATH}" -f "${SDK_PATH}" .
rm -rf "${SDK_OUTPUT_PATH}"

{
	echo "KERNEL_ARCH=${TARGET_ARCH_STANDARD}"
	echo "KERNEL_VERSION=${KERNEL_VERSION}"
	echo "KERNEL_FLAVOR=${KERNEL_FLAVOR}"
	sha256sum "${KERNEL_OBJ}/.config" | awk '{print "KERNEL_CONFIG=sha256:"$1}'
} >"${METADATA_PATH}"
gzip -9 <"${KERNEL_OBJ}/.config" >"${CONFIG_GZ_PATH}"
