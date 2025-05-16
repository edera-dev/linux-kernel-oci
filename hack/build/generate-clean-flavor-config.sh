#!/bin/sh

if [ $# -ne 4 ]; then
		cat << EOF
Usage: $(basename "$0") <kernel_version> <arch> <edera_flavor_config> <delta_config>

Fetch an arch-specific kernel default configuration for a specific stable kernel version and compare it
with another (local) config, outputting a config containing only the changed/added lines from the kernel default.

Arguments:
		<kernel_version>  The stable kernel version to fetch (e.g., "6.14.6")
		<arch>            Target architecture (x86_64, arm64, arm)
		<new_config>      Path to the new kernel config file to compare against
		<output_file>     Path where the fragment containing only modified options will be saved.

Example:
		$(basename "$0") 6.14.6 x86_64 /edera_<host/zone>.config zone.config

Notes:
		- The Edera flavor config does not have to be a complete kernel config,
		  but starting from a complete Edera flavor config you know boots is recommended.
		- The script will fetch the default config for the specified released version from kernel.org CDN
		- Comment lines/unset opts (starting with #) are filtered out
		- Only lines that were added or changed in <edera_flavor_config> are saved
		- <output_file> must end in '.config' or kernel make will complain.
EOF
		exit 1
fi

UPSTREAM_KVER="$1"
ARCH="$2"
FULL_EDERA_FLAVOR_CONFIG="$3"
DELTA_EDERA_FLAVOR_CONFIG="$4"
TEMP_DIR="$(mktemp -d)-$UPSTREAM_KVER-$ARCH"

# Cleanup temp dir always
trap 'rm -rf "$TEMP_DIR"; echo "Cleaning up temporary files..."; exit' INT TERM EXIT

KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v$(echo "$UPSTREAM_KVER" | cut -d. -f1).x/linux-${UPSTREAM_KVER}.tar.xz"
TARBALL_PATH="$TEMP_DIR/linux-${UPSTREAM_KVER}.tar.xz"

if [ ! -f "$FULL_EDERA_FLAVOR_CONFIG" ]; then
		echo "Error: Complete Edera kernel config file does not exist at $FULL_EDERA_FLAVOR_CONFIG!"
		exit 1
fi

echo "Fetching kernel.org stable kernel default config for version $UPSTREAM_KVER (arch: $ARCH)..."

# Map architecture names to kernel arch names and config paths
case "$ARCH" in
		x86_64)
				CONFIG_SNIP="arch/x86/configs/x86_64_defconfig"
				;;
		arm64|aarch64)
				CONFIG_SNIP="arch/arm64/configs/defconfig"
				;;
		*)
				echo "Error: Unsupported architecture: $ARCH"
				exit 1
				;;
esac

# Extract only the config file we need
mkdir -p "$TEMP_DIR/linux"
echo "Downloading released kernel $UPSTREAM_KVER from $KERNEL_URL to $TARBALL_PATH"
if ! curl -sSL "$KERNEL_URL" -o "$TARBALL_PATH"; then
		echo "Error: Failed to download kernel version $UPSTREAM_KVER."
		exit 1
fi

if ! tar -xf "$TARBALL_PATH" --strip-components=1 -C "$TEMP_DIR/linux" "linux-${UPSTREAM_KVER}/$CONFIG_SNIP"; then
		echo "Error: Failed to extract config file from the tarball."
		exit 1
fi

CONFIG_PATH="$TEMP_DIR/linux/$CONFIG_SNIP"

if [ -f "$CONFIG_PATH" ]; then
		echo "Generating a trimmed delta config between kernel $UPSTREAM_KVER default config for $ARCH and Edera flavor config $FULL_EDERA_FLAVOR_CONFIG"
	./hack/build/generate-kfragment.sh "$CONFIG_PATH" "$FULL_EDERA_FLAVOR_CONFIG" "$DELTA_EDERA_FLAVOR_CONFIG"
else
		echo "Error: Config file not found at $CONFIG_PATH"
		exit 1
fi

echo "trimmed delta config saved to $DELTA_EDERA_FLAVOR_CONFIG"
