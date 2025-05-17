#!/usr/bin/env sh

if [ $# -ne 3 ]; then
	cat << EOF
Usage: $(basename "$0") <old_config> <new_config> <output_file>

Diff two kernel configuration files and output a "fragment" containing
only the changed/added lines from <new_config> to <output_file>, ignoring comments.

Arguments:
	<old_config>   Path to the original/baseline kernel config file. For edera, this should usually be 'zone.config' or 'host.config'
	<new_config>   Path to the new kernel config file, with changes from 'zone/host.config'
	<output_file>  Path where the fragment containing only the options the new kernel config modified will be saved. Note that it must end in '.config' or kernel make will complain.

Example:
	$(basename "$0") configs/x86_64/zone.config my_other_kernel_with_funky_options.config zone-funky.fragment.config

Notes:
	- Comment lines (starting with #) are filtered out
	- Only lines that were added or changed in <new_config> are saved
EOF
	exit 1
fi

# Check if input files exist
if [ ! -f "$1" ]; then
	echo "Error: Base config file '$1' does not exist."
fi

if [ ! -f "$2" ]; then
	echo "Error: Updated config file '$2' does not exist."
fi

cat > "$3"<< EOF
#
# Edera kernel config snippet
# - Generated from delta config: $2
# - Against base config: $1
#
EOF

diff -u "$1" "$2" | grep '^+' | grep -v '^+++' | sed 's/^+//' | grep -v '^[[:space:]]*#' >> "$3"
