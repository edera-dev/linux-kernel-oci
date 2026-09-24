#!/usr/bin/env bash
#
# Measure zone kernel boot time under Cloud Hypervisor (the real KVM path). Builds
# each flavor (zone, zone-tiny) once and caches the bzImage under KCACHE; re-runs
# reuse a valid cached kernel (REBUILD=1 forces a rebuild). Each kernel is
# PVH-booted by cloud-hypervisor with a minimal busybox initramfs that powers off
# immediately; hyperfine benchmarks the VM-boot wall-clock (warmup + mean/stddev +
# an N-times-faster comparison), and one extra boot samples in-guest /proc/uptime
# for the config-isolated kernel->init time.
#
# Lives in hack/bench/; the repo root is derived from this script's location, so it
# runs from any working directory. Uses upstream cloud-hypervisor: set CHV=/path, or
# have `cloud-hypervisor` on PATH, else the static release binary is fetched to
# KCACHE. Needs /dev/kvm. Not the full protect zone boot.
# x86_64 only. Needs: docker (buildx), podman, hyperfine (+ curl if fetching CHV).
#
# Usage:
#   hack/bench/measure-boot-time.sh                   # build/cache zone + zone-tiny, compare
#   REBUILD=1 hack/bench/measure-boot-time.sh         # force rebuild
#   RUNS=15 FLAVORS="zone zone-tiny" hack/bench/measure-boot-time.sh
#   hack/bench/measure-boot-time.sh /tmp/a.bzImage /tmp/b.bzImage   # measure given images
set -euo pipefail

RUNS="${RUNS:-100}"
while getopts "n:" opt; do
	case "$opt" in
	n) RUNS="$OPTARG" ;;
	*)
		echo "usage: $0 [-n RUNS] [kernel...]" >&2
		exit 2
		;;
	esac
done
shift $((OPTIND - 1))

for tool in hyperfine docker podman; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "ERROR: '$tool' not found on the host." >&2
		exit 3
	}
done

BENCH_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_REPO="${KERNEL_REPO:-$(cd -- "$BENCH_DIR/../.." && pwd)}"
ARCH="${ARCH:-x86_64}"
SERIES="${SERIES:-6.18}"
FLAVORS="${FLAVORS:-zone zone-tiny}"
REGISTRY="${REGISTRY:-127.0.0.1:5000}"
REG_NAME="${REG_NAME:-edera-local-registry}"
# no sccache backend locally, and its wrapper can fail the kernel assembler probe
export KERNEL_DISABLE_SCCACHE="${KERNEL_DISABLE_SCCACHE-1}"
KCACHE="${KCACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/edera-kernel-bench}"
export KCACHE # visible to hack/bench/chv-wrap-run.sh when $CHV points at it
CHV_URL="${CHV_URL:-https://github.com/cloud-hypervisor/cloud-hypervisor/releases/latest/download/cloud-hypervisor-static}"
# Extra args passed straight to cloud-hypervisor. Use e.g. "--seccomp false" when running
# inside a sandbox that blocks the seccomp() syscall (see hack/bench/Dockerfile.runner).
CHV_EXTRA_ARGS="${CHV_EXTRA_ARGS:-}"

mkdir -p "$KCACHE"
CHV="${CHV:-}"
if [ -z "$CHV" ]; then
	if command -v cloud-hypervisor >/dev/null 2>&1; then
		CHV="cloud-hypervisor"
	else
		CHV="$KCACHE/cloud-hypervisor"
		if [ ! -x "$CHV" ]; then
			command -v curl >/dev/null 2>&1 || {
				echo "ERROR: need cloud-hypervisor on PATH, CHV=/path, or curl to fetch it." >&2
				exit 3
			}
			echo ">> fetching upstream cloud-hypervisor -> $CHV" >&2
			curl -fsSL -o "$CHV" "$CHV_URL"
			chmod +x "$CHV"
		fi
	fi
fi
[ -n "${SKIP_KVM_CHECK:-}" ] || [ -e /dev/kvm ] || {
	echo "ERROR: /dev/kvm not available; Cloud Hypervisor needs KVM." >&2
	echo "       (set SKIP_KVM_CHECK=1 when using hack/bench/chv-wrap-run.sh)" >&2
	exit 3
}

WORK="$(mktemp -d)"
export WORK # visible to hack/bench/chv-wrap-run.sh when $CHV points at it
CFG_BAK=""
cleanup() {
	rm -rf "$WORK" 2>/dev/null || true
	[ -n "$CFG_BAK" ] && mv -f "$CFG_BAK" "$KERNEL_REPO/config.yaml" 2>/dev/null || true
}
trap cleanup EXIT

valid_kernel() {
	local k="$1" sz
	[ -f "$k" ] || return 1
	sz=$(stat -c %s "$k" 2>/dev/null || echo 0)
	[ "$sz" -gt 1000000 ] || return 1
	if command -v file >/dev/null 2>&1; then
		file -b "$k" | grep -qiE 'bzImage|kernel' || return 1
	fi
	return 0
}

ensure_build_env() {
	[ -n "${BUILD_ENV_READY:-}" ] && return 0
	docker container inspect "$REG_NAME" >/dev/null 2>&1 ||
		docker run -d --name "$REG_NAME" --restart=unless-stopped \
			-p 127.0.0.1:5000:5000 docker.io/library/registry:2 >/dev/null
	CFG_BAK="$KERNEL_REPO/config.yaml.bootbak"
	cp "$KERNEL_REPO/config.yaml" "$CFG_BAK"
	sed -i "s|^imageNameFormat:.*|imageNameFormat: \"${REGISTRY}/edera-dev/[image]:[tag]\"|" "$KERNEL_REPO/config.yaml"
	BUILD_ENV_READY=1
}

# ---- collect kernels: explicit paths, or build/cache each flavor ----
ORDER=()
declare -A KPATH
if [ "$#" -ge 1 ]; then
	for k in "$@"; do
		l="$(basename "$k")"
		ORDER+=("$l")
		KPATH[$l]="$k"
	done
else
	cd "$KERNEL_REPO"
	for f in $FLAVORS; do
		cache="$KCACHE/${f}-${SERIES}.bzImage"
		if [ -z "${REBUILD:-}" ] && valid_kernel "$cache"; then
			echo ">> reusing cached $f  ($cache)" >&2
		else
			ensure_build_env
			echo ">> building $f ..." >&2
			docker buildx rm edera >/dev/null 2>&1 || true
			if ! KERNEL_ARCHITECTURES="$ARCH" ./hack/build/docker-build.sh \
				"stable:flavor=${f};series=${SERIES}" >"/tmp/kboot-${f}.log" 2>&1; then
				echo "   build FAILED for $f (see /tmp/kboot-${f}.log)" >&2
				continue
			fi
			if ! valid_kernel target/kernel; then
				echo "   build produced no valid target/kernel for $f" >&2
				continue
			fi
			cp target/kernel "$cache"
		fi
		valid_kernel "$cache" || {
			echo "   no valid kernel for $f, skipping" >&2
			continue
		}
		ORDER+=("$f")
		KPATH[$f]="$cache"
	done
	cd - >/dev/null
fi
[ "${#ORDER[@]}" -ge 1 ] || {
	echo "no kernels to measure" >&2
	exit 1
}

# ---- initramfs: busybox + a /init that samples uptime and powers off. Built
# entirely inside the container (no host bind-mount) and streamed out. ----
INIT_B64=$(
	base64 -w0 <<'EOF'
#!/bin/sh
mount -t proc none /proc 2>/dev/null
read -r up _ < /proc/uptime
echo "BOOT_UPTIME=${up}"
poweroff -f
EOF
)
if ! podman run --rm docker.io/library/busybox:musl sh -c '
	set -e; R=/tmp/r; mkdir -p "$R/bin"
	echo '"$INIT_B64"' | base64 -d > "$R/init"; chmod +x "$R/init"
	for a in sh mount poweroff; do ln -sf /bin/busybox "$R/bin/$a"; done
	cp /bin/busybox "$R/bin/busybox"
	cd "$R" && find . | cpio -o -H newc 2>/dev/null | gzip -9
' >"$WORK/initrd.cpio.gz" 2>"$WORK/initramfs.err"; then
	echo "ERROR: initramfs build failed:" >&2
	cat "$WORK/initramfs.err" >&2
	exit 4
fi
[ -s "$WORK/initrd.cpio.gz" ] || {
	echo "ERROR: empty initrd.cpio.gz:" >&2
	cat "$WORK/initramfs.err" >&2
	exit 4
}

# ---- cloud-hypervisor PVH boot; guest serial -> a file we can read.
# cmdline matches protect's default container-zone boot (earlyprintk + console on
# ttyS0, quiet); protect also appends init.zone.memory.min=N and any caller args. ----
APPEND="earlyprintk=ttyS0 console=ttyS0 quiet"
chvcmd() { # $1 = kernel, $2 = serial output file
	echo "timeout 60 '$CHV' $CHV_EXTRA_ARGS --kernel '$1' --initramfs '$WORK/initrd.cpio.gz' --cmdline '$APPEND' --cpus boot=1 --memory size=512M --serial file='$2' --console off"
}

# ---- preflight: confirm a boot actually reaches /init, else numbers are noise ----
eval "$(chvcmd "${KPATH[${ORDER[0]}]}" "$WORK/pre.log")" >/dev/null 2>&1 || true
grep -q '^BOOT_UPTIME=' "$WORK/pre.log" 2>/dev/null || {
	echo "ERROR: cloud-hypervisor boot did not reach /init (no BOOT_UPTIME). Serial tail:" >&2
	tail -n 25 "$WORK/pre.log" 2>/dev/null >&2 || true
	exit 4
}

# ---- single in-guest kernel->init sample per flavor ----
echo
for label in "${ORDER[@]}"; do
	eval "$(chvcmd "${KPATH[$label]}" "$WORK/con.log")" >/dev/null 2>&1 || true
	up=$(sed -n 's/^BOOT_UPTIME=//p' "$WORK/con.log" | tail -1 | tr -d '\r')
	printf 'kernel->init  %-14s %ss\n' "$label" "${up:-?}"
done

# ---- hyperfine wall-clock VM-boot benchmark ----
hf=(hyperfine --shell=sh --warmup 2 --runs "$RUNS")
for label in "${ORDER[@]}"; do
	hf+=(-n "$label" "$(chvcmd "${KPATH[$label]}" /dev/null) >/dev/null 2>&1")
done
echo
echo "hyperfine command:"
line="  "
i=0
while [ "$i" -lt "${#hf[@]}" ]; do
	if [ "${hf[$i]}" = "-n" ]; then
		printf '%s\n' "$line"
		line="    -n ${hf[$((i + 1))]} ${hf[$((i + 2))]}"
		i=$((i + 3))
	else
		line="$line ${hf[$i]}"
		i=$((i + 1))
	fi
done
printf '%s\n\n' "$line"
"${hf[@]}"
