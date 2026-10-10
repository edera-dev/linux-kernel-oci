#!/bin/bash
set -e

# Sourced from firmware.sh; the TPU needs no firmware, only the hook that binds it to vfio-pci.
if [ "${KERNEL_FLAVOR}" = "zone-tpu" ]; then
	install -Dm644 "${KERNEL_DIR}/hooks/tpu-vfio.toml" "${ADDONS_OUTPUT_PATH}/hooks/tpu-vfio.toml"
fi
