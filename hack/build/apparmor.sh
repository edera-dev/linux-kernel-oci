#!/bin/sh
# Compiles the Edera 'RuntimeDefault' AppArmor profile against the zone kernel's ABI,
# and stages it in the addon overlay at apparmor/.
#
# Only zone kernels run workloads; the host kernel has no use for the profile,
# so it is skipped there.
#
# Requires apparmor_parser in the build environment.

case "${KERNEL_FLAVOR}" in
zone*)
	APPARMOR_OUTPUT_PATH="${ADDONS_OUTPUT_PATH}/apparmor"
	PROFILE_SRC="${KERNEL_DIR}/configs/apparmor/edera-default"

	mkdir -p "${APPARMOR_OUTPUT_PATH}"

	# Compile to a loadable binary policy without attempting to load it into the current kernel.
	# The cache file apparmor_parser writes is what we load into the  guest kernel via its `.load` interface.
	APPARMOR_CACHE_DIR="$(mktemp -d)"
	apparmor_parser --skip-kernel-load -M /etc/apparmor.d/abi/3.0 --write-cache \
		--cache-loc="${APPARMOR_CACHE_DIR}" "${PROFILE_SRC}"

	# Drop the compiled policy under <cache>/<abi-hash>/<name>
	# alongside a shared `.features` file.
	COMPILED="$(find "${APPARMOR_CACHE_DIR}" -type f ! -name '.features' | head -n1)"
	if [ -z "${COMPILED}" ]; then
		echo "ERROR: apparmor_parser produced no compiled policy for ${PROFILE_SRC}" >&2
		exit 1
	fi
	cp "${COMPILED}" "${APPARMOR_OUTPUT_PATH}/edera-default"
	rm -rf "${APPARMOR_CACHE_DIR}"
	;;
esac
