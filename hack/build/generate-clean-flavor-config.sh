#!/bin/sh

if [ $# -ne 4 ]; then
	cat <<USAGE
Usage: $(basename "$0") <branch_ref> <arch> <customized_flavor_config> <output_delta_flavor_config>

Fetch an arch-specific kernel default configuration from a branch of the Edera Linux tree and compare it
with another (local) config, outputting a delta flavor config containing only the changed/added lines from the kernel default.

Arguments:
		<branch_ref>									Branch of the Edera Linux tree to compare against (e.g. edera/6.18-lts)
		<arch>												Target architecture (x86_64, arm64, arm)
		<customized_flavor_config>		Path to the new kernel config file to compare against. May be complete, or a fragment.
		<output_delta_flavor_config>	Path where the fragment containing only modified options will be saved.

Example:
		$(basename "$0") edera/6.18-lts x86_64 /edera_<host/zone>.config zone.config

Notes:
		- The Edera flavor config does not have to be a complete kernel config,
			but starting from a complete Edera flavor config you know boots is recommended.
		- The branch is resolved to a commit and the defconfig is fetched from that commit,
			so the comparison is against an exact tree rather than a moving branch.
		- Comment lines/unset opts (starting with #) are filtered out
		- Only lines that were added or changed in <edera_flavor_config> are saved
		- <output_file> must end in '.config' or kernel make will complain.
		- Run this from the repository root; it reads source.repo out of config.yaml.
USAGE
	exit 1
fi

BRANCH_REF="$1"
ARCH="$2"
FULL_EDERA_FLAVOR_CONFIG="$3"
DELTA_EDERA_FLAVOR_CONFIG="$4"

if [ ! -f "$FULL_EDERA_FLAVOR_CONFIG" ]; then
	echo "Error: Complete Edera kernel config file does not exist at $FULL_EDERA_FLAVOR_CONFIG!"
	exit 1
fi

# Map architecture names to kernel arch names and config paths
case "$ARCH" in
x86_64)
	CONFIG_SNIP="arch/x86/configs/x86_64_defconfig"
	;;
arm64 | aarch64)
	CONFIG_SNIP="arch/arm64/configs/defconfig"
	;;
*)
	echo "Error: Unsupported architecture: $ARCH"
	exit 1
	;;
esac

SOURCE_REPO="$(awk '/^source:/{in_source=1; next} in_source && /^[^[:space:]]/{exit} in_source && $1 == "repo:" {print $2; exit}' config.yaml)"

if [ -z "$SOURCE_REPO" ]; then
	echo "Error: could not read source.repo from config.yaml (run this from the repository root)"
	exit 1
fi

# Resolve to a commit first: a raw URL built from a branch name containing a
# slash is ambiguous, and a commit pins the comparison to one exact tree.
COMMIT="$(git ls-remote --heads "$SOURCE_REPO" "refs/heads/${BRANCH_REF}" | cut -f1)"

if [ -z "$COMMIT" ]; then
	echo "Error: branch $BRANCH_REF does not exist on $SOURCE_REPO"
	exit 1
fi

SLUG="${SOURCE_REPO#https://github.com/}"
SLUG="${SLUG%.git}"
CONFIG_URL="https://raw.githubusercontent.com/${SLUG}/${COMMIT}/${CONFIG_SNIP}"

TEMP_DIR="$(mktemp -d)"
# Cleanup temp dir always
trap 'rm -rf "$TEMP_DIR"; echo "Cleaning up temporary files..."; exit' INT TERM EXIT

CONFIG_PATH="$TEMP_DIR/defconfig"

echo "Fetching $CONFIG_SNIP from $BRANCH_REF ($COMMIT) for $ARCH..."
if ! curl -sSLf "$CONFIG_URL" -o "$CONFIG_PATH"; then
	echo "Error: Failed to download $CONFIG_URL."
	exit 1
fi

echo "Generating a trimmed delta flavor config between $BRANCH_REF's default config for $ARCH and flavor config $FULL_EDERA_FLAVOR_CONFIG"
./hack/build/generate-kfragment.sh "$CONFIG_PATH" "$FULL_EDERA_FLAVOR_CONFIG" "$DELTA_EDERA_FLAVOR_CONFIG"

echo "trimmed flavor delta config saved to $DELTA_EDERA_FLAVOR_CONFIG"
