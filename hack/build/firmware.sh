#!/bin/bash
set -e

# shellcheck disable=SC2034
FIRMWARE_OUTPUT_PATH="${ADDONS_OUTPUT_PATH}/firmware"
WORKLOAD_OVERLAY_PATH="${ADDONS_OUTPUT_PATH}/overlays/workload"

# Any firmwares (if any needed) that should ultimately end up in the squashfs
# should be sitting at this location when this script finishes.
# (will go in ${ADDONS_PATH}/firmware, siblings with `${ADDONS_PATH}/modules`)
mkdir -p "${FIRMWARE_OUTPUT_PATH}"

if [ -n "${FIRMWARE_SIG_URL}" ]; then
	# Getting the pubkey from the signature is slightly stupid, ideally we should maintain
	# a list of valid keys out-of-band, this is best-effort.
	echo "Found firmware signature $FIRMWARE_SIG_URL, attempting validation"

	# Check if FIRMWARE_URL exists and is a regular file
	if [ ! -f "$FIRMWARE_URL" ]; then
		echo "ERROR: $FIRMWARE_URL does not exist or is not a regular file"
		echo "ERROR: If this was intentional, consider unsetting '$FIRMWARE_SIG_URL'"
		exit 1
	fi

	KEY_INFO=$(gpg --verify "$FIRMWARE_SIG_URL" "$FIRMWARE_URL" 2>&1) || true
	KEY_ID=$(echo "$KEY_INFO" | grep -E "using .* key|key ID" | grep -oE "[A-F0-9]{40}|[A-F0-9]{16,}")
	gpg --recv-key "$KEY_ID"
	unxz "$FIRMWARE_URL"
	# We've uncompressed it, update the env var so later stuff points at the right file
	FIRMWARE_URL="${FIRMWARE_URL%.xz}"
	gpg --verify "$FIRMWARE_SIG_URL" || { echo "ERROR: signature ${FIRMWARE_SIG_URL} cannot validate ${FIRMWARE_URL}"; exit 1; }
else
	echo "No firmware signature defined, no validation will be performed"
fi


# Note that this assumes the archive is a .tar file, and has already been validated elsewhere.
if [ -n "${FIRMWARE_URL}" ]; then
	echo "untarring firmware at $FIRMWARE_URL"
	tar -xf "${FIRMWARE_URL}" -C "${FIRMWARE_OUTPUT_PATH}" --strip-components=1
	# For amdgpu zone kernel, we only want the amdgpu firmwares, so remove the rest to keep the addons small
	if [ "${KERNEL_FLAVOR}" = "zone-amdgpu" ]; then
		OLDDIR=$PWD
		cd "${FIRMWARE_OUTPUT_PATH}"
		find . -maxdepth 1 ! -name 'amdgpu' ! -name "." -exec rm -rf {} +
		# Compress firmwares on-disk
		# As of 6.x kernels the kconfig explicitly says you must use crc32 or none, not the default crc64.
		xz -C crc32 amdgpu/*
		cd "${OLDDIR}"
	fi
fi

# For nvidia kernel, firmware is distributed via their out-of-tree .run userspace
# package, which we need to fetch and extract.
# TODO(BML) fix arm64 builds
if [ "${KERNEL_FLAVOR}" = "zone-nvidiagpu" ] && [ "${TARGET_ARCH_STANDARD}" = "x86_64" ]; then
	# Check that we already set NV_VERSION when building the out-of-tree kmod,
	# naturally, we must fetch the matching runtime package.
	if [ -z "${NV_VERSION}" ]; then
		echo "ERROR: flavor is zone-nvidiagpu but no NV_VERSION is set"
		exit 1
	fi

	OLDDIR=$PWD

	# TBH it's probably the same firmware regardless
	if [ "${TARGET_ARCH_STANDARD}" = "aarch64" ]; then
		NV_RUN_FILE="NVIDIA-Linux-aarch64-${NV_VERSION}.run"
		NV_RUN_URL="https://us.download.nvidia.com/XFree86/aarch64/${NV_VERSION}/${NV_RUN_FILE}"
	elif [ "${TARGET_ARCH_STANDARD}" = "x86_64" ]; then
		NV_RUN_FILE="NVIDIA-Linux-x86_64-${NV_VERSION}.run"
		NV_RUN_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${NV_VERSION}/${NV_RUN_FILE}"
	fi

	NV_EXTRACT_PATH="$(mktemp -d)/extracted-${NV_VERSION}"
	mkdir -p "$NV_EXTRACT_PATH"

	echo "Downloading NVIDIA runtime package for driver ${NV_VERSION} from: $NV_RUN_URL"
	curl --retry 5 --retry-delay 2 --retry-max-time 30 --retry-all-errors -L -o "$NV_EXTRACT_PATH/$NV_RUN_FILE" "$NV_RUN_URL"
	chmod +x "$NV_EXTRACT_PATH/$NV_RUN_FILE"
	"$NV_EXTRACT_PATH/$NV_RUN_FILE" -x --target "$NV_EXTRACT_PATH/out"
	# Compress firmwares on-disk
	# As of 6.x kernels the kconfig explicitly says you must use crc32 or none, not the default crc64.
	xz -C crc32 "$NV_EXTRACT_PATH"/out/firmware/*
	ls -lah "$NV_EXTRACT_PATH/out/firmware/"
	NV_FW_PATH="${FIRMWARE_OUTPUT_PATH}/nvidia/$NV_VERSION"
	mkdir -p "${NV_FW_PATH}"
	cp "$NV_EXTRACT_PATH"/out/firmware/*.xz "${NV_FW_PATH}"

	#
	# Workload overlay
	#
	# Install various binaries necessary to make compute workloads run properly
	# under containers.
	#

	create_links() {
		local base_path="$1"
		# create soname links
		find "$base_path" -type f -name '*.so*' ! -path '*xorg/*' -print0 | while read -d $'\0' _lib; do
			_soname=$(dirname "${_lib}")/$(readelf -d "${_lib}" | grep -Po 'SONAME.*: \[\K[^]]*' || true)
			_base=$(echo ${_soname} | sed -r 's/(.*)\.so.*/\1.so/')
			[[ -e "${_soname}" ]] || ln -s $(basename "${_lib}") "${_soname}"
			[[ -e "${_base}" ]] || ln -s $(basename "${_soname}") "${_base}"
		done
	}

	multiarch_symlink_mirror() {
		local base_path="$1"
		local triplet="$2"
		local src="${base_path}/usr/lib"
		local dst="${base_path}/usr/lib/${triplet}"
		pushd "$src" >/dev/null

		# 1) Recreate directory structure (excluding the triplet subtree to avoid recursion)
		# Use find from within src to get clean relative paths like "./gbm"

		# Create directories
		find . \
			-mindepth 1 \
			-path "./${triplet}/*" -prune -o \
			-path "./${triplet}" -prune -o \
			-type d -print0 \
		| while IFS= read -r -d '' rel_dir; do
				# Strip leading "./"
				rel_dir="${rel_dir#./}"
				mkdir -p "${dst}/${rel_dir}"
			done

		# Helper: decide whether to mirror this path
		should_mirror() {
			local p="$1"
			if [[ -f "$p" ]]; then
				# regular file -> yes
				return 0
			elif [[ -L "$p" ]]; then
				# symlink -> only if it ultimately targets a regular file
				# resolve; readlink -f fails (non-zero) on broken loops/broken links
				local tgt
				if ! tgt="$(readlink -f -- "$p" 2>/dev/null)"; then
					return 1
				fi
				[[ -f "$tgt" ]] && return 0 || return 1
			else
				# sockets, fifos, device nodes, etc. -> no
				return 1
			fi
		}

		# 2) Mirror regular files and symlinks-to-regular-files
		find . \
			-path "./${triplet}/*" -prune -o \
			\( -type f -o -type l \) \
			-print0 \
		| while IFS= read -r -d '' rel_item; do
				rel_item="${rel_item#./}"
				# Filter: only files and symlinks that resolve to files
				if ! should_mirror "$rel_item"; then
					continue
				fi

				local link_path="${dst}/${rel_item}"
				local link_dir
				link_dir="$(dirname "$link_path")"
				mkdir -p "$link_dir"

				# Always point the mirror symlink to the *original path in /usr/lib*,
				# preserving whether the original is a file or a symlink.
				local target="../${rel_item}"

				if [[ -L "$link_path" ]]; then
					ln -snf "$target" "$link_path"
				elif [[ -e "$link_path" ]]; then
					echo "WARN: exists and not a symlink, skipping: $link_path" >&2
				else
					ln -s "$target" "$link_path"
				fi
			done

		popd >/dev/null
	}

	# GTK (used by nvidia-settings, which we don't install)
	rm -f "$NV_EXTRACT_PATH/out"/libnvidia-gtk*

	# Wayland/GBM
	mkdir -p "$WORKLOAD_OVERLAY_PATH/usr/lib/gbm"
	ln -s ../libnvidia-allocator.so.$NV_VERSION "$WORKLOAD_OVERLAY_PATH/usr/lib/gbm/nvidia-drm_gbm.so"

	# DRI driver
	install -Dm755 "$NV_EXTRACT_PATH/out/"nvidia_drv.so "$WORKLOAD_OVERLAY_PATH/usr/lib/xorg/modules/drivers/nvidia_drv.so"

	# GLX extensions
	install -Dm755 "$NV_EXTRACT_PATH/out/"libglxserver_nvidia.so.$NV_VERSION "$WORKLOAD_OVERLAY_PATH/usr/lib/nvidia/xorg/libglxserver_nvidia.so.$NV_VERSION"
	ln -s libglxserver_nvidia.so.$NV_VERSION "$WORKLOAD_OVERLAY_PATH/usr/lib/nvidia/xorg/libglxserver_nvidia.so.1"
	ln -s libglxserver_nvidia.so.$NV_VERSION "$WORKLOAD_OVERLAY_PATH/usr/lib/nvidia/xorg/libglxserver_nvidia.so"

	# Remove already-installed libs, so we don't accidentally include them in
	# filters below
	rm -f "$NV_EXTRACT_PATH/out"/nvidia-drv.so
	rm -f "$NV_EXTRACT_PATH/out"/libglxserver_*

	# Remove unnecessary libraries
	rm -f "$NV_EXTRACT_PATH/out"/libnvidia-wayland*

	for LIBRARY in "$NV_EXTRACT_PATH/out/"lib*.so*; do
		BN="$(basename "$LIBRARY")"
		install -Dm755 "$LIBRARY" "$WORKLOAD_OVERLAY_PATH/usr/lib/$BN"
	done

	for BINARY in "$NV_EXTRACT_PATH/out/"nvidia-{cuda-mps-control,cuda-mps-server,debugdump,pcc,smi}; do
		BN="$(basename "$BINARY")"
		install -Dm755 "$BINARY" "$WORKLOAD_OVERLAY_PATH/usr/bin/$BN"
	done

	for MAN1 in "$NV_EXTRACT_PATH/out/"nvidia-{cuda-mps-control,smi}.1.gz; do
		BN="$(basename "$MAN1")"
		install -Dm644 "$MAN1" "$WORKLOAD_OVERLAY_PATH/usr/share/man/man1/$BN"
	done

	# Install ICD loaders for OpenGL, Vulkan, and Vulkan SC
	install -Dm644 "$NV_EXTRACT_PATH/out/"10_nvidia.json "$WORKLOAD_OVERLAY_PATH/usr/share/glvnd/egl_vendor.d/10_nvidia.json"
	install -Dm644 "$NV_EXTRACT_PATH/out/"nvidia.icd "$WORKLOAD_OVERLAY_PATH/etc/OpenCL/vendors/nvidia.icd"
	install -Dm644 "$NV_EXTRACT_PATH/out/"nvidia_icd.json "$WORKLOAD_OVERLAY_PATH/usr/share/vulkan/icd.d/nvidia_icd.json"
	install -Dm644 "$NV_EXTRACT_PATH/out/"nvidia_layers.json "$WORKLOAD_OVERLAY_PATH/usr/share/vulkan/implicit_layer.d/nvidia_layers.json"
	install -Dm644 "$NV_EXTRACT_PATH/out/"nvidia_icd_vksc.json "$WORKLOAD_OVERLAY_PATH/usr/share/vulkansc/icd.d/nvidia_icd_vksc.json"

	create_links "$WORKLOAD_OVERLAY_PATH"

	# For Debian-like distributions
	multiarch_symlink_mirror "$WORKLOAD_OVERLAY_PATH" x86_64-linux-gnu

	#
	# Create NVIDIA persistence mode hook, ensures the driver is loaded and
	# initialized, and always ready to run a workload
	#
	NVIDIA_BOOTSTRAP_OVERLAY_PATH="$ADDONS_OUTPUT_PATH/overlays/nvidia-bootstrap"

	mkdir -p "$NVIDIA_BOOTSTRAP_OVERLAY_PATH"

	for BINARY in "$NV_EXTRACT_PATH/out/"nvidia-smi; do
		BN="$(basename "$BINARY")"
		install -Dm755 "$BINARY" "$NVIDIA_BOOTSTRAP_OVERLAY_PATH/usr/bin/$BN"
	done

	# HACK: Just using the builder's glibc binaries so we can run nvidia-smi
	# without a full workload image
	for LIBRARY in "$NV_EXTRACT_PATH/out/"libnvidia-ml.so* /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/lib{pthread,m,dl,c,rt}.so.*; do
		BN="$(basename "$LIBRARY")"
		install -Dm755 "$LIBRARY" "$NVIDIA_BOOTSTRAP_OVERLAY_PATH/usr/lib/$BN"
	done
	ln -s usr/lib "$NVIDIA_BOOTSTRAP_OVERLAY_PATH/lib64"

	create_links "$NVIDIA_BOOTSTRAP_OVERLAY_PATH"
	multiarch_symlink_mirror "$NVIDIA_BOOTSTRAP_OVERLAY_PATH" x86_64-linux-gnu

	mkdir -p "$ADDONS_OUTPUT_PATH/hooks"
	cat > "$ADDONS_OUTPUT_PATH/hooks/nvidia-persist.toml" <<-EOF
[[hooks.setup]]
modules = ["nvidia", "nvidia_drm"]
execute = ["/usr/bin/nvidia-smi", "-pm", "1"]
ignore-failure = true

[[hooks.hotplug]]
modules = ["nvidia", "nvidia_drm"]
execute = ["/usr/bin/nvidia-smi", "-pm", "1"]
ignore-failure = true
EOF

	cd "$OLDDIR"
fi
