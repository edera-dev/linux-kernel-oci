#!/usr/bin/env bash
#
# Run the hyperbench microbenchmark inside a zone kernel under Cloud Hypervisor
# (the real KVM path) and compare kernel arms. Builds/caches a bzImage per base
# flavor under KCACHE, embeds the static hyperbench binary in a busybox initramfs,
# PVH-boots each arm N times, and parses hyperbench's per-test microseconds
# (lower is better) into a mean +/- stddev table with a delta-% vs the baseline.
#
# Its point is the arm list: each FLAVORS entry is <flavor>[:<extra-cmdline>], so
# the built kernel is measured against the stock kernel AND the stock kernel with
# the equivalent *runtime* knob. The default arms isolate "needs a new kernel
# image" (zone-nomit) from "needs a boot knob" (zone mitigations=off):
#   zone                    stock, mitigations on
#   zone:mitigations=off    stock kernel, mitigations disabled at runtime
#   zone-nomit              mitigations compiled out
# PipeCopy/SocketPairCopy are syscall-bound (mitigation-sensitive); ShaCrypt/Sieve
# are pure compute and act as negative controls.
#
# Lives in hack/bench/; repo root is derived from this script's location, so it
# runs from any working directory. Uses upstream cloud-hypervisor: set CHV=/path,
# or have `cloud-hypervisor` on PATH, else the static release binary is fetched to
# KCACHE. Needs /dev/kvm. x86_64 only.
# Needs: docker (buildx), podman (+ curl if fetching CHV). The hyperbench binary is
# taken from HYPERBENCH_BIN if set, else built from HYPERBENCH_SRC (a hyperbench
# checkout; default: sibling of the kernel repo).
#
# Usage:
#   hack/bench/run-hyperbench.sh                        # default 3-arm comparison
#   RUNS=8 hack/bench/run-hyperbench.sh
#   FLAVORS="zone zone-nomit" hack/bench/run-hyperbench.sh
#   KVER=6.18.52 hack/bench/run-hyperbench.sh          # pin exact kernel version
#   HYPERBENCH_BIN=/path/to/static/hyperbench hack/bench/run-hyperbench.sh
set -euo pipefail

RUNS="${RUNS:-5}"
while getopts "n:" opt; do
	case "$opt" in
	n) RUNS="$OPTARG" ;;
	*)
		echo "usage: $0 [-n RUNS]" >&2
		exit 2
		;;
	esac
done
shift $((OPTIND - 1))

for tool in docker podman; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "ERROR: '$tool' not found on the host." >&2
		exit 3
	}
done

BENCH_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_REPO="${KERNEL_REPO:-$(cd -- "$BENCH_DIR/../.." && pwd)}"
ARCH="${ARCH:-x86_64}"
SERIES="${SERIES:-6.18}"
FLAVORS="${FLAVORS:-zone zone:mitigations=off zone-nomit}"
REGISTRY="${REGISTRY:-127.0.0.1:5000}"
REG_NAME="${REG_NAME:-edera-local-registry}"
TIMEOUT="${TIMEOUT:-300}"
CPUS="${CPUS:-8}"
# hyperbench's L1d probe allocates a 1GiB scratch buffer, so the guest needs well
# over 1GiB or it OOMs before the first test runs.
MEM="${MEM:-2048M}"
HYPERBENCH_SRC="${HYPERBENCH_SRC:-$(dirname "$KERNEL_REPO")/hyperbench}"
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

# ---- static hyperbench binary: reuse HYPERBENCH_BIN, else build the image (FROM
# scratch with /bin/hyperbench) and extract the binary once, cached under KCACHE ----
HB_BIN=""
obtain_hyperbench() {
	if [ -n "${HYPERBENCH_BIN:-}" ]; then
		[ -x "$HYPERBENCH_BIN" ] || {
			echo "ERROR: HYPERBENCH_BIN='$HYPERBENCH_BIN' is not executable." >&2
			exit 3
		}
		HB_BIN="$HYPERBENCH_BIN"
		return 0
	fi
	local cache="$KCACHE/hyperbench.bin" cid
	if [ -z "${REBUILD:-}" ] && [ -x "$cache" ]; then
		HB_BIN="$cache"
		return 0
	fi
	[ -f "$HYPERBENCH_SRC/Dockerfile" ] || {
		echo "ERROR: no hyperbench Dockerfile at HYPERBENCH_SRC='$HYPERBENCH_SRC'." >&2
		echo "       Set HYPERBENCH_BIN=/path/to/static/hyperbench or HYPERBENCH_SRC=/path/to/hyperbench." >&2
		exit 3
	}
	echo ">> building hyperbench from $HYPERBENCH_SRC ..." >&2
	docker build -t edera-hyperbench-bench "$HYPERBENCH_SRC" >"/tmp/hyperbench-build.log" 2>&1 || {
		echo "   hyperbench build FAILED (see /tmp/hyperbench-build.log)" >&2
		exit 3
	}
	cid="$(docker create edera-hyperbench-bench)" || {
		echo "   docker create failed" >&2
		exit 3
	}
	if ! docker cp "$cid:/bin/hyperbench" "$cache" >/dev/null 2>&1; then
		docker rm -f "$cid" >/dev/null 2>&1 || true
		echo "   could not extract /bin/hyperbench from the image" >&2
		exit 3
	fi
	docker rm -f "$cid" >/dev/null 2>&1 || true
	chmod +x "$cache"
	HB_BIN="$cache"
}

# ---- collect arms: each FLAVORS entry is <flavor>[:<extra-cmdline>]; build each
# distinct base flavor once and reuse it across arms that share it ----
declare -a ORDER=()
declare -A KPATH=()
declare -A ACMD=()
declare -A BUILT=()
BASE_PATH=""
build_base() { # $1 = base flavor; sets BASE_PATH; returns 1 on failure
	local base="$1" cache
	BASE_PATH=""
	if [ -n "${BUILT[$base]:-}" ]; then
		BASE_PATH="${BUILT[$base]}"
		return 0
	fi
	cache="$KCACHE/${base}-${SERIES}.bzImage"
	if [ -z "${REBUILD:-}" ] && valid_kernel "$cache"; then
		echo ">> reusing cached $base  ($cache)" >&2
	else
		ensure_build_env
		echo ">> building $base ..." >&2
		docker buildx rm edera >/dev/null 2>&1 || true
		# KVER pins an exact kernel version (manual spec); otherwise stable = the
		# latest point release of SERIES. Pinning keeps every arm on one version and
		# avoids a point release whose carried patches happen to be broken.
		local spec="stable:flavor=${base};series=${SERIES}"
		[ -n "${KVER:-}" ] && spec="manual:flavor=${base};exact=${KVER}"
		if ! KERNEL_ARCHITECTURES="$ARCH" ./hack/build/docker-build.sh \
			"$spec" >"/tmp/kbench-${base}.log" 2>&1; then
			echo "   build FAILED for $base (see /tmp/kbench-${base}.log)" >&2
			return 1
		fi
		if ! valid_kernel target/kernel; then
			echo "   build produced no valid target/kernel for $base" >&2
			return 1
		fi
		cp target/kernel "$cache"
	fi
	valid_kernel "$cache" || return 1
	BUILT[$base]="$cache"
	BASE_PATH="$cache"
	return 0
}

obtain_hyperbench
cd "$KERNEL_REPO"
# shellcheck disable=SC2086 # deliberate word-split of the FLAVORS arm list
for entry in $FLAVORS; do
	base="${entry%%:*}"
	extra=""
	[ "$entry" != "$base" ] && extra="${entry#*:}"
	if ! build_base "$base"; then
		echo "   skipping arm '$entry' (base $base unavailable)" >&2
		continue
	fi
	ORDER+=("$entry")
	KPATH[$entry]="$BASE_PATH"
	ACMD[$entry]="$extra"
done
cd - >/dev/null
[ "${#ORDER[@]}" -ge 1 ] || {
	echo "no kernels to measure" >&2
	exit 1
}

# ---- initramfs: busybox + the static hyperbench binary + a /init that records
# the mitigation state, runs hyperbench, and powers off. Built inside the container
# with the host binary bind-mounted read-only. ----
INIT_B64=$(
	base64 -w0 <<'EOF'
#!/bin/sh
mount -t proc none /proc 2>/dev/null
mount -t sysfs none /sys 2>/dev/null
echo "CMDLINE=$(cat /proc/cmdline)"
for v in spectre_v2 meltdown mds; do
f=/sys/devices/system/cpu/vulnerabilities/$v
[ -r "$f" ] && echo "MIT_${v}=$(cat "$f")"
done
PROF=$(sed -n 's/.*prof=\([a-z-]*\).*/\1/p' /proc/cmdline)
case "$PROF" in
compute)
echo 0 > /proc/sys/kernel/sched_autogroup_enabled 2>/dev/null
;;
esac
echo "PROF=${PROF:-none}"
echo "APPLIED_autogroup=$(cat /proc/sys/kernel/sched_autogroup_enabled 2>/dev/null)"
/bin/hyperbench
echo "HB_DONE=1"
poweroff -f
EOF
)
# The hyperbench binary comes in on stdin (not a bind mount): a rootless/SELinux
# host denies the container access to a mounted host file, and building the image
# entirely in-container is how measure-boot-time.sh already avoids that.
if ! podman run --rm -i docker.io/library/busybox:musl sh -c '
	set -e; R=/tmp/r; mkdir -p "$R/bin" "$R/proc" "$R/sys"
	echo '"$INIT_B64"' | base64 -d > "$R/init"; chmod +x "$R/init"
	for a in sh mount poweroff cat sed; do ln -sf /bin/busybox "$R/bin/$a"; done
	cp /bin/busybox "$R/bin/busybox"
	cat > "$R/bin/hyperbench"; chmod +x "$R/bin/hyperbench"
	cd "$R" && find . | cpio -o -H newc 2>/dev/null | gzip -9
' <"$HB_BIN" >"$WORK/initrd.cpio.gz" 2>"$WORK/initramfs.err"; then
	echo "ERROR: initramfs build failed:" >&2
	cat "$WORK/initramfs.err" >&2
	exit 4
fi
[ -s "$WORK/initrd.cpio.gz" ] || {
	echo "ERROR: empty initrd.cpio.gz:" >&2
	cat "$WORK/initramfs.err" >&2
	exit 4
}

# ---- cloud-hypervisor PVH boot; guest serial -> a file we parse. Optional PIN
# (host cpuset) pins the VMM for less run-to-run noise. ----
APPEND_BASE="earlyprintk=ttyS0 console=ttyS0 quiet"
PINPFX=""
[ -n "${PIN:-}" ] && PINPFX="taskset -c '$PIN' "
chvcmd() { # $1 = kernel, $2 = serial output file, $3 = extra cmdline
	echo "timeout $TIMEOUT ${PINPFX}'$CHV' $CHV_EXTRA_ARGS --kernel '$1' --initramfs '$WORK/initrd.cpio.gz' --cmdline '$APPEND_BASE ${3:-}' --cpus boot=$CPUS --memory size=$MEM --serial file='$2' --console off"
}

# ---- preflight: confirm a boot actually completes hyperbench, else it is noise ----
eval "$(chvcmd "${KPATH[${ORDER[0]}]}" "$WORK/pre.log" "${ACMD[${ORDER[0]}]}")" >/dev/null 2>&1 || true
grep -q '^HB_DONE=' "$WORK/pre.log" 2>/dev/null || {
	echo "ERROR: boot did not complete hyperbench (no HB_DONE). Serial tail:" >&2
	tail -n 25 "$WORK/pre.log" 2>/dev/null >&2 || true
	exit 4
}
cp -f "$WORK/pre.log" /tmp/hyperbench-preflight.log 2>/dev/null || true
grep -q "^Test '" "$WORK/pre.log" 2>/dev/null || {
	echo "ERROR: hyperbench booted (HB_DONE seen) but printed no 'Test' lines -- it likely" >&2
	echo "       OOMed; its L1d probe allocates ~1GiB and the guest has MEM=$MEM. Raise MEM." >&2
	echo "       Full serial saved to /tmp/hyperbench-preflight.log. Tail:" >&2
	tail -n 25 "$WORK/pre.log" 2>/dev/null >&2 || true
	exit 4
}

# ---- measure each arm RUNS times, accumulating per-test samples ----
declare -A SAMP=()
declare -a METRICS=()
declare -A SEEN=()
declare -A MITV=()
add_metric() { [ -n "${SEEN[$1]:-}" ] || {
	METRICS+=("$1")
	SEEN[$1]=1
}; }

for label in "${ORDER[@]}"; do
	echo ">> measuring $label ($RUNS runs) ..." >&2
	r=0
	while [ "$r" -lt "$RUNS" ]; do
		eval "$(chvcmd "${KPATH[$label]}" "$WORK/con.log" "${ACMD[$label]}")" >/dev/null 2>&1 || true
		while IFS='|' read -r name val; do
			[ -n "$name" ] || continue
			add_metric "$name"
			SAMP["$label|$name"]="${SAMP["$label|$name"]:-} $val"
		done < <(sed -n "s/^Test '\(.*\)': \([0-9][0-9.]*\).*/\1|\2/p" "$WORK/con.log")
		score=$(sed -n 's/^Final score[^:]*: \([0-9][0-9.]*\).*/\1/p' "$WORK/con.log" | tail -1 | tr -d '\r')
		[ -n "$score" ] && {
			add_metric "Final score"
			SAMP["$label|Final score"]="${SAMP["$label|Final score"]:-} $score"
		}
		r=$((r + 1))
	done
	MITV[$label]=$(sed -n 's/^MIT_spectre_v2=//p' "$WORK/con.log" | tail -1 | tr -d '\r')
done

# ---- mean/stddev and delta-% vs the baseline arm ----
MO_M=0
MO_SD=0
mean_of() { # $1 = "label|metric"; sets MO_M MO_SD; returns 1 if no samples
	local vals="${SAMP[$1]:-}"
	[ -n "${vals// /}" ] || return 1
	read -r MO_M MO_SD < <(printf '%s\n' "$vals" |
		awk '{n=NF;s=0;for(i=1;i<=n;i++)s+=$i;m=s/n;v=0;for(i=1;i<=n;i++){d=$i-m;v+=d*d}sd=(n>1)?sqrt(v/(n-1)):0;printf "%.1f %.1f\n",m,sd}')
	return 0
}

base_label="${ORDER[0]}"
# widen the metric column to the longest test name so values stay aligned
w=6
for metric in "${METRICS[@]}"; do [ "${#metric}" -gt "$w" ] && w="${#metric}"; done
w=$((w + 2))
echo
echo "== hyperbench: elapsed microseconds, lower is better (N=$RUNS boots/arm) =="
echo "   delta% is vs baseline '$base_label'; negative = faster"
echo
printf '%-*s' "$w" "metric"
for label in "${ORDER[@]}"; do printf '%-28s' "$label"; done
echo
for metric in "${METRICS[@]}"; do
	printf '%-*s' "$w" "$metric"
	bm=""
	mean_of "$base_label|$metric" && bm="$MO_M"
	for label in "${ORDER[@]}"; do
		if mean_of "$label|$metric"; then
			cell="$(printf '%.0f+-%.0f' "$MO_M" "$MO_SD")"
			if [ "$label" != "$base_label" ] && [ -n "$bm" ]; then
				pct=$(awk -v a="$MO_M" -v b="$bm" 'BEGIN{printf "%+.1f",(a/b-1)*100}')
				cell="$cell (${pct}%)"
			fi
		else
			cell="n/a"
		fi
		printf '%-28s' "$cell"
	done
	echo
done

echo
echo "== in-guest CPU-vulnerability state (spectre_v2, last run) =="
for label in "${ORDER[@]}"; do
	printf '%-22s %s\n' "$label" "${MITV[$label]:-?}"
done
for label in "${ORDER[@]}"; do
	[ "${label%%:*}" = "zone-nomit" ] || continue
	case "${MITV[$label]:-}" in
	*Vulnerable*) : ;;
	*) echo "WARNING: $label still reports mitigations active ('${MITV[$label]:-}'); the fragment may not have taken -- check 'zcat target/config.gz | grep CPU_MITIGATIONS'." >&2 ;;
	esac
done
