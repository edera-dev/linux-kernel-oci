#!/bin/sh

if [ $# -ne 4 ]; then
		cat << EOF
Usage: $(basename "$0") <edera_base_flavor> <arch> <customized_variant_config> <output_delta_variant_config>

Fetch an arch-specific Edera base flavor kernel configuration and compare it with another (local) config,
outputting a delta variant config containing only the changed/added lines from the kernel default.

Arguments:
		<edera_base_flavor>						The edera flavor to start from ("zone" or "host")
		<arch>												Target OCI image architecture (amd64, arm64)
		<customized_variant_config>		Path to the customized, complete variant kernel config file to compare against
		<output_delta_variant_config>	Path where the delta config containing only modified options will be saved.

Example:
		$(basename "$0") zone amd64 /boot/myflavorvariant.config zone-myflavorvariant.config

Notes:
		- The script will fetch the latest released flavor config for the specified flavor from ghcr.io/edera-dev
		- Comment lines/unset opts (starting with #) are filtered out
		- Only lines that were added or changed in <customized_variant_config> are saved in <output_delta_variant_config>
		- <output_delta_variant_config> must end in '.config' or kernel make will complain.
EOF
		exit 1
fi

FLAVOR="$1"
ARCH="$2"
CUSTOMIZED_VARIANT_CONFIG="$3"
DELTA_VARIANT_CONFIG="$4"

# Map architecture names to OCI-ified versions
case "$ARCH" in
		x86_64)
				ARCH="amd64"
				;;
		arm64|aarch64)
				ARCH="arm64"
				;;
		*)
				echo "Error: Unsupported architecture: $ARCH"
				exit 1
				;;
esac

TEMP_DIR="$(mktemp -d)-$FLAVOR-$ARCH"
# Cleanup temp dir always
trap 'rm -rf "$TEMP_DIR"; echo "Cleaning up temporary files..."; exit' INT TERM EXIT

crane export "ghcr.io/edera-dev/$FLAVOR-kernel:latest" - --platform=linux/"$ARCH" | tar --keep-directory-symlink -xf - -C "$TEMP_DIR"

if [ ! -f "$TEMP_DIR/kernel/config.gz" ]; then
		echo "Error: Exported Edera flavor config file does not exist at $TEMP_DIR/kernel/config.gz!"
		exit 1
fi

gunzip "$TEMP_DIR/kernel/config.gz"

EXTRACTED_CONFIG="$TEMP_DIR/kernel/config.gz"

if [ -f "$EXTRACTED_CONFIG" ]; then
		echo "Generating a trimmed delta variant config between latest edera $FLAVOR kernel config for $ARCH and $CUSTOMIZED_VARIANT_CONFIG"
	./hack/build/generate-kfragment.sh "$EXTRACTED_CONFIG" "$CUSTOMIZED_VARIANT_CONFIG" "$DELTA_VARIANT_CONFIG"
else
		echo "Error: Config file not found at $EXTRACTED_CONFIG"
		exit 1
fi

echo "trimmed delta variant config saved to $DELTA_VARIANT_CONFIG"
