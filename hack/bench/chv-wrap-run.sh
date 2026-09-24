#!/bin/sh
# Drop-in replacement for the cloud-hypervisor binary: exec CHV inside a container so
# /dev/kvm is reachable in environments where the host does not expose /dev/kvm but each
# spawned container does. The bench scripts point $CHV at this wrapper.
#
# Bind-mounts $KCACHE (read-only, for cached bzImages) and $WORK (read-write, for the
# initramfs/scratch disk/serial output) into the same host paths inside the container so
# every --kernel / --initramfs / --disk / --serial path the caller passes still resolves.
# --network=none is deliberate: CHV needs no network for these benches, and it sidesteps
# any bridge-network setup entirely. --init is NOT used: some sandbox environments inject
# a seal at init that requires an out-of-band policy, and CHV needs no zombie reaping.
#
# Uses: KCACHE, WORK (must be exported by the caller), CHV_CONTAINER_IMAGE (defaults to
# edera-bench-runner), plus whatever CHV args the caller forwards on the command line.
set -eu

: "${KCACHE:?run this via the bench scripts; KCACHE must be set and exported}"
: "${WORK:?run this via the bench scripts; WORK must be set and exported}"

image="${CHV_CONTAINER_IMAGE:-edera-bench-runner}"

exec podman run --rm --network=none \
	-v "${KCACHE}":"${KCACHE}":ro \
	-v "${WORK}":"${WORK}" \
	"${image}" \
	/usr/local/bin/cloud-hypervisor "$@"
