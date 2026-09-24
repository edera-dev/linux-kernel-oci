#!/usr/bin/env bash
#
# Simpler kernel builder for the bench harness. Runs the kernel compile inside
# a single debian:bookworm-slim container -- no docker-in-docker, no kernel-
# buildenv image, no docker buildx. Works in the clampdown sandbox precisely
# because it avoids all three: containers have net + full toolchain, and the
# source lives at /tmp/src (not /build, so sandbox-seal's Landlock allows exec).
#
# Kernel-oci's docker-build.sh does more (multi-stage buildkit, addons squashfs,
# SDK, module signing, sccache-Azure). None of that is needed for a bench
# bzImage -- this script produces just the bzImage.
#
# Lives in hack/bench/build/; kernel-oci repo root is derived from the script's
# location. Runs from any working directory.
#
# Env vars:
#   KVER       exact kernel version (default 6.18.52; pinned to dodge the
#              broken 0003-x86-amd_node patch on stable 6.18.53)
#   SERIES     bzImage filename series suffix (default 6.18)
#   DEST       where to stage the bzImage (default <edera-root>/.claude/kcache)
#   FLAVOR     which flavor to build (positional arg overrides this env)
#   IMAGE      base debian image (default docker.io/library/debian:bookworm-slim)
#   JOBS       parallel make jobs (default $(nproc))
#
# Usage:
#   hack/bench/build/build-kernel.sh zone-tiny
#   KVER=6.18.52 hack/bench/build/build-kernel.sh zone-nomit
#   DEST=/some/path hack/bench/build/build-kernel.sh zone-lto
set -euo pipefail

if [ $# -ge 1 ]; then FLAVOR="$1"; fi
: "${FLAVOR:?usage: build-kernel.sh <flavor>}"

BENCH_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_REPO="$(cd -- "$BENCH_DIR/../../.." && pwd)"
EDERA_ROOT="$(cd -- "$KERNEL_REPO/.." && pwd)"

KVER="${KVER:-6.18.52}"
SERIES="${SERIES:-6.18}"
DEST="${DEST:-$EDERA_ROOT/.claude/kcache}"
IMAGE="${IMAGE:-edera-kernel-builder}"
JOBS="${JOBS:-}"

mkdir -p "$DEST"

# Build the builder image once. Subsequent runs reuse it (podman inspect returns
# non-zero if the image is absent). REBUILD_IMAGE=1 forces a rebuild.
if [ -n "${REBUILD_IMAGE:-}" ] || ! podman image inspect "$IMAGE" >/dev/null 2>&1; then
	echo ">> building builder image $IMAGE from hack/bench/build/Dockerfile"
	podman build -t "$IMAGE" -f "$BENCH_DIR/Dockerfile" "$BENCH_DIR"
fi

# LTO wants clang-18 from apt.llvm.org (bookworm's clang-14 predates the kernel's
# minimum). For every other flavor we build with gcc from bookworm.
IS_LTO=0
[ "$FLAVOR" = "zone-lto" ] && IS_LTO=1
# zone-tiny uses `make tinyconfig` as its base, not the arch defconfig.
IS_TINY=0
[ "$FLAVOR" = "zone-tiny" ] && IS_TINY=1

command -v podman >/dev/null 2>&1 || {
	echo "ERROR: podman not found." >&2
	exit 3
}

echo ">> building $FLAVOR at $KVER via a debian container ($IMAGE)" >&2
echo "   staging to $DEST/${FLAVOR}-${SERIES}.bzImage" >&2

# Everything below runs inside the container. The kernel repo is mounted read-only
# at /repo, the destination writable at /out. Sources land under /tmp/src (not
# /build) so sandbox-seal permits `make` and its helpers to exec.
podman run --rm \
	-v "$KERNEL_REPO":/repo:ro \
	-v "$DEST":/out \
	-e FLAVOR="$FLAVOR" \
	-e KVER="$KVER" \
	-e SERIES="$SERIES" \
	-e IS_LTO="$IS_LTO" \
	-e IS_TINY="$IS_TINY" \
	-e JOBS="${JOBS}" \
	-w /tmp \
	"$IMAGE" \
	bash -c '
set -euo pipefail

echo "==> fetching linux-${KVER}.tar.xz"
KMAJ="${KVER%%.*}"
curl -fsSL -o /tmp/linux.txz \
	"https://cdn.kernel.org/pub/linux/kernel/v${KMAJ}.x/linux-${KVER}.tar.xz"
tar xf /tmp/linux.txz -C /tmp
rm -f /tmp/linux.txz
SRC=/tmp/linux-${KVER}
cd "$SRC"

if [ -f /repo/hack/build/patchlist.py ]; then
	echo "==> applying patches for ${FLAVOR} @ ${KVER}"
	# patchlist.py imports matrix.py which reads config.yaml with a CWD-relative
	# path, so it must be invoked from the repo root.
	PATCHES=$(cd /repo && python3 hack/build/patchlist.py "$KVER" "$FLAVOR")
	if [ -n "$PATCHES" ]; then
		echo "$PATCHES" | while IFS= read -r p; do
			[ -n "$p" ] || continue
			echo "   patch: $p"
			patch --verbose -p1 <"/repo/$p" >/dev/null
		done
	fi
else
	echo "==> no patchlist.py in repo -- upstream tarball built as-is (Edera patches are"
	echo "    now in the edera-dev/linux branch; use that as source for a patched build)."
fi

echo "==> preparing config"
# copy config artifacts into the source tree so the kernel Makefile can merge them
cp "/repo/configs/x86_64/zone.config" arch/x86/configs/ 2>/dev/null || true
if [ "$IS_TINY" = 1 ]; then
	cp "/repo/configs/x86_64/zone-tiny.config" arch/x86/configs/
	# tinyconfig base + explicit allowlist
	make ARCH=x86 tinyconfig >/dev/null
	# shellcheck disable=SC2086
	make ARCH=x86 zone-tiny.config >/dev/null
else
	FRAG="zone-${FLAVOR#zone-}.fragment.config"
	if [ "$FLAVOR" != "zone" ]; then
		cp "/repo/configs/x86_64/$FRAG" arch/x86/configs/
		# arch defconfig base + zone.config delta + flavor fragment delta
		LLVM_MAKE=""; [ "$IS_LTO" = 1 ] && LLVM_MAKE="LLVM=-18"
		# shellcheck disable=SC2086
		make ARCH=x86 $LLVM_MAKE olddefconfig zone.config "$FRAG" >/dev/null
	else
		LLVM_MAKE=""; [ "$IS_LTO" = 1 ] && LLVM_MAKE="LLVM=-18"
		# shellcheck disable=SC2086
		make ARCH=x86 $LLVM_MAKE olddefconfig zone.config >/dev/null
	fi
fi

# Verify the flavor knob actually survived config resolution (guards silent
# fragment-merge failures like the ones we hit in earlier work).
case "$FLAVOR" in
zone-nomit) grep -qE "^# CONFIG_CPU_MITIGATIONS is not set" .config \
	|| { echo "ERROR: zone-nomit fragment did not take (CPU_MITIGATIONS still set)"; exit 4; } ;;
zone-rt)    grep -qE "^CONFIG_PREEMPT_RT=y" .config \
	|| { echo "ERROR: zone-rt fragment did not take (PREEMPT_RT missing)"; exit 4; } ;;
zone-lto)   grep -qE "^CONFIG_LTO_CLANG_THIN=y" .config \
	|| { echo "ERROR: zone-lto fragment did not take (LTO_CLANG_THIN missing -- Clang not selected?)"; exit 4; } ;;
esac

: "${JOBS:=$(nproc)}"
echo "==> building bzImage (JOBS=$JOBS)"
LLVM_MAKE=""; [ "$IS_LTO" = 1 ] && LLVM_MAKE="LLVM=-18"
# shellcheck disable=SC2086
time make ARCH=x86 $LLVM_MAKE -j"$JOBS" bzImage

sz=$(stat -c %s arch/x86/boot/bzImage)
echo "==> bzImage ready: ${sz} bytes"
cp arch/x86/boot/bzImage "/out/${FLAVOR}-${SERIES}.bzImage"
echo "==> staged /out/${FLAVOR}-${SERIES}.bzImage"
'
