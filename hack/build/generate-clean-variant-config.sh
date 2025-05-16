#!/bin/sh

if [ $# -ne 5 ]; then
		cat << EOF
Usage: $(basename "$0") <edera_base_flavor> <edera_flavor_kver> <arch> <customized_variant_config> <output_delta_variant_config>

Fetch an arch-specific Edera base flavor kernel configuration and compare it with another (local) config,
outputting a delta variant config containing only the changed/added lines from the Ederad flavor default.

Arguments:
		<edera_base_flavor>						The edera flavor to start from ("zone" or "host")
		<edera_flavor_kver>           The edera flavor kernel version to base this off of (recommend oldest-supported kver)
		<arch>												Target OCI image architecture (amd64, arm64)
		<customized_variant_config>		Path to the customized, complete variant kernel config file to compare against
		<output_delta_variant_config>	Path where the delta config containing only modified options will be saved.

Example:
		$(basename "$0") zone 5.4.293 amd64 /boot/myflavorvariant.config zone-myflavorvariant.config

Notes:
		- The script will fetch the latest released flavor config for the specified flavor from ghcr.io/edera-dev
		- Comment lines/unset opts (starting with #) are filtered out
		- Only lines that were added or changed in <customized_variant_config> are saved in <output_delta_variant_config>
		- <output_delta_variant_config> must end in '.config' or kernel make will complain.
EOF
		exit 1
fi

FLAVOR="$1"
VERSION="$2"
ARCH="$3"
CUSTOMIZED_VARIANT_CONFIG="$4"
DELTA_VARIANT_CONFIG="$5"

TEMP_DIR="$(mktemp -d)-$FLAVOR-$VERSION-$ARCH"
mkdir -p "$TEMP_DIR"
# Cleanup temp dir always
trap 'rm -rf "$TEMP_DIR"; echo "Cleaning up temporary files..."; exit' INT TERM EXIT

crane export "ghcr.io/edera-dev/$FLAVOR-kernel:$VERSION" - --platform=linux/"$ARCH" | tar --keep-directory-symlink -xf - -C "$TEMP_DIR"

if [ ! -f "$TEMP_DIR/kernel/config.gz" ]; then
		echo "Error: Exported Edera flavor config file does not exist at $TEMP_DIR/kernel/config.gz!"
		exit 1
fi

gunzip "$TEMP_DIR/kernel/config.gz"

EXTRACTED_CONFIG="$TEMP_DIR/kernel/config"

if [ -f "$EXTRACTED_CONFIG" ]; then
		echo "Generating a trimmed delta variant config between latest edera $FLAVOR kernel config for $ARCH and $CUSTOMIZED_VARIANT_CONFIG"
	./hack/build/generate-kfragment.sh "$EXTRACTED_CONFIG" "$CUSTOMIZED_VARIANT_CONFIG" "$DELTA_VARIANT_CONFIG"
else
		echo "Error: Config file not found at $EXTRACTED_CONFIG"
		exit 1
fi

echo "trimmed delta variant config saved to $DELTA_VARIANT_CONFIG"
