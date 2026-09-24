#!/usr/bin/env bash
#
# Run cyclictest inside a zone kernel under Cloud Hypervisor (the real KVM path),
# under background CPU load, and compare kernel arms by wake-up latency. Builds/
# caches a bzImage per base flavor under KCACHE, embeds static cyclictest + hackbench
# binaries in a busybox initramfs, boots each arm on CPUS vCPUs N times, and reports
# min/avg/max latency in microseconds (lower is better). RT's win is the bounded
# worst case (max) under contention.
#
# Like run-hyperbench.sh, each FLAVORS entry is <flavor>[:<extra-cmdline>], so the
# built kernel is measured against the stock kernel AND the stock kernel with the
# equivalent runtime knob. The default arms isolate "needs a new kernel image"
# (zone-rt) from "needs a boot knob" (zone preempt=full, via PREEMPT_DYNAMIC):
#   zone                 stock, PREEMPT_NONE default
#   zone:preempt=full    stock kernel switched to full preemption at boot
#   zone-rt              PREEMPT_RT compiled in
#
# Lives in hack/bench/; repo root is derived from this script's location, so it
# runs from any working directory. Uses upstream cloud-hypervisor: set CHV=/path,
# or have `cloud-hypervisor` on PATH, else the static release binary is fetched to
# KCACHE. Needs /dev/kvm. x86_64 only.
# Needs: docker (buildx), podman (+ curl if fetching CHV). cyclictest and hackbench are
# taken from CYCLICTEST_BIN / HACKBENCH_BIN if set, else built static from rt-tests
# (CYC_REF) in a container.
#
# LOAD selects the background load: spin (userspace busy loops, default) or hackbench
# (kernel-heavy scheduling/locking/IPIs -- the load where PREEMPT_RT actually bounds the
# tail). Host-CPU isolation still matters: on a busy host, pin with PIN=<cpus>.
#
# Usage:
#   hack/bench/run-cyclictest.sh                        # default 3-arm comparison
#   RUNS=5 CPUS=4 DURATION=60 hack/bench/run-cyclictest.sh
#   FLAVORS="zone zone-rt" hack/bench/run-cyclictest.sh
#   LOAD=hackbench PIN=2,3 hack/bench/run-cyclictest.sh # kernel-heavy load, pinned
#   KVER=6.18.52 hack/bench/run-cyclictest.sh          # pin exact kernel version
#   CYCLICTEST_BIN=/path/to/static/cyclictest hack/bench/run-cyclictest.sh
set -euo pipefail

RUNS="${RUNS:-3}"
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
FLAVORS="${FLAVORS:-zone zone:preempt=full zone-rt}"
REGISTRY="${REGISTRY:-127.0.0.1:5000}"
REG_NAME="${REG_NAME:-edera-local-registry}"
CPUS="${CPUS:-8}"
DURATION="${DURATION:-30}"
TIMEOUT="${TIMEOUT:-$((DURATION + 90))}"
CYC_REF="${CYC_REF:-v2.8}"
LOAD="${LOAD:-spin}"
[ "$LOAD" = spin ] || [ "$LOAD" = hackbench ] || {
	echo "ERROR: LOAD must be 'spin' or 'hackbench' (got '$LOAD')." >&2
	exit 2
}
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

# ---- static cyclictest + hackbench: reuse CYCLICTEST_BIN / HACKBENCH_BIN, else build
# both from rt-tests fully static and cache them. rt-tests 2.x hard-requires libnuma, so
# we build on Debian bookworm (it ships libnuma.a, and its glibc predates the sched_attr
# declaration that clashes with rt-tests' headers on newer glibc) and static-link via
# CC='gcc -static' -- the results run self-contained in the musl busybox initramfs. ----
CT_BIN=""
HACK_BIN=""
obtain_load_bins() {
	CT_BIN="${CYCLICTEST_BIN:-$KCACHE/cyclictest.bin}"
	HACK_BIN="${HACKBENCH_BIN:-$KCACHE/hackbench.bin}"
	local need="" cid ok
	if [ -z "${CYCLICTEST_BIN:-}" ] && { [ -n "${REBUILD:-}" ] || [ ! -x "$CT_BIN" ]; }; then need=1; fi
	if [ -z "${HACKBENCH_BIN:-}" ] && { [ -n "${REBUILD:-}" ] || [ ! -x "$HACK_BIN" ]; }; then need=1; fi
	if [ -n "$need" ]; then
		echo ">> building static cyclictest + hackbench (rt-tests $CYC_REF) ..." >&2
		cat >"$WORK/Dockerfile.cyc" <<EOF
FROM docker.io/library/debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libnuma-dev git ca-certificates python3 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${CYC_REF} https://git.kernel.org/pub/scm/utils/rt-tests/rt-tests.git /rt
RUN make -C /rt CC="gcc -static" cyclictest hackbench && (cp /rt/cyclictest /cyclictest 2>/dev/null || cp "\$(find /rt -type f -name cyclictest | head -1)" /cyclictest) && (cp /rt/hackbench /hackbench 2>/dev/null || cp "\$(find /rt -type f -name hackbench | head -1)" /hackbench)
EOF
		if ! docker build -t edera-cyclictest-bench -f "$WORK/Dockerfile.cyc" "$WORK" >"/tmp/cyclictest-build.log" 2>&1; then
			echo "   build FAILED (see /tmp/cyclictest-build.log)" >&2
			echo "   set CYCLICTEST_BIN / HACKBENCH_BIN to static binaries, or a valid CYC_REF." >&2
			exit 3
		fi
		cid="$(docker create edera-cyclictest-bench)" || {
			echo "   docker create failed" >&2
			exit 3
		}
		ok=1
		[ -n "${CYCLICTEST_BIN:-}" ] || docker cp "$cid:/cyclictest" "$CT_BIN" >/dev/null 2>&1 || ok=""
		[ -n "${HACKBENCH_BIN:-}" ] || docker cp "$cid:/hackbench" "$HACK_BIN" >/dev/null 2>&1 || ok=""
		docker rm -f "$cid" >/dev/null 2>&1 || true
		[ -n "$ok" ] || {
			echo "   could not extract binaries from the image" >&2
			exit 3
		}
		[ -n "${CYCLICTEST_BIN:-}" ] || chmod +x "$CT_BIN"
		[ -n "${HACKBENCH_BIN:-}" ] || chmod +x "$HACK_BIN"
	fi
	[ -x "$CT_BIN" ] || {
		echo "ERROR: cyclictest binary '$CT_BIN' not executable." >&2
		exit 3
	}
	[ -x "$HACK_BIN" ] || {
		echo "ERROR: hackbench binary '$HACK_BIN' not executable." >&2
		exit 3
	}
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

obtain_load_bins
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

# ---- initramfs: busybox + static cyclictest + a /init that records the RT state,
# spawns CPU load, runs cyclictest, and powers off. Duration and load-thread count
# come in on the kernel cmdline (cyc.dur, cyc.load) so the image stays generic. ----
INIT_B64=$(
	base64 -w0 <<'EOF'
#!/bin/sh
mount -t proc none /proc 2>/dev/null
mount -t sysfs none /sys 2>/dev/null
echo "CMDLINE=$(cat /proc/cmdline)"
echo "RT_uname=$(uname -a)"
case "$(uname -a)" in *PREEMPT_RT*) echo "RT_realtime=1" ;; *) echo "RT_realtime=0" ;; esac
DUR=$(sed -n 's/.*cyc\.dur=\([0-9][0-9]*\).*/\1/p' /proc/cmdline); DUR=${DUR:-30}
NLOAD=$(sed -n 's/.*cyc\.load=\([0-9][0-9]*\).*/\1/p' /proc/cmdline); NLOAD=${NLOAD:-1}
LK=$(sed -n 's/.*cyc\.loadkind=\([a-z][a-z]*\).*/\1/p' /proc/cmdline); LK=${LK:-spin}
PROF=$(sed -n 's/.*prof=\([a-z-]*\).*/\1/p' /proc/cmdline)
case "$PROF" in
latency)
echo 0 > /proc/sys/kernel/timer_migration 2>/dev/null
echo -1 > /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null
echo 0 > /proc/sys/kernel/sched_autogroup_enabled 2>/dev/null
;;
esac
echo "PROF=${PROF:-none}"
echo "APPLIED_timer_migration=$(cat /proc/sys/kernel/timer_migration 2>/dev/null)"
echo "APPLIED_sched_rt_runtime_us=$(cat /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null)"
echo "APPLIED_autogroup=$(cat /proc/sys/kernel/sched_autogroup_enabled 2>/dev/null)"
echo "LOADKIND=$LK"
if [ "$LK" = hackbench ]; then
( while : ; do /bin/hackbench -g "$NLOAD" -l 1000 >/dev/null 2>&1 || sleep 1 ; done ) &
else
i=0
while [ "$i" -lt "$NLOAD" ]; do
sh -c 'while : ; do : ; done' &
i=$((i + 1))
done
fi
out="$(/bin/cyclictest -m -q -p99 -i200 -d0 -D${DUR} -a0 -t1 2>/dev/null)"
echo "CYC_min=$(echo "$out" | sed -n 's/.*Min:[ ]*\([0-9][0-9]*\).*/\1/p' | tail -1)"
echo "CYC_avg=$(echo "$out" | sed -n 's/.*Avg:[ ]*\([0-9][0-9]*\).*/\1/p' | tail -1)"
echo "CYC_max=$(echo "$out" | sed -n 's/.*Max:[ ]*\([0-9][0-9]*\).*/\1/p' | tail -1)"
echo "CT_DONE=1"
poweroff -f
EOF
)
# The load binaries come in on stdin as a tar (not a bind mount): a rootless/SELinux
# host denies the container access to mounted host files, and building the image
# entirely in-container is how measure-boot-time.sh already avoids that.
cp "$CT_BIN" "$WORK/cyclictest.pl"
cp "$HACK_BIN" "$WORK/hackbench.pl"
if ! tar -C "$WORK" -c cyclictest.pl hackbench.pl | podman run --rm -i docker.io/library/busybox:musl sh -c '
	set -e; R=/tmp/r; mkdir -p "$R/bin" "$R/proc" "$R/sys" /tmp/pl
	echo '"$INIT_B64"' | base64 -d > "$R/init"; chmod +x "$R/init"
	for a in sh mount poweroff cat sed uname tail sleep; do ln -sf /bin/busybox "$R/bin/$a"; done
	cp /bin/busybox "$R/bin/busybox"
	tar -x -C /tmp/pl
	cp /tmp/pl/cyclictest.pl "$R/bin/cyclictest"; chmod +x "$R/bin/cyclictest"
	cp /tmp/pl/hackbench.pl "$R/bin/hackbench"; chmod +x "$R/bin/hackbench"
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

# ---- cloud-hypervisor PVH boot on CPUS vCPUs; guest serial -> a file we parse.
# Optional PIN (host cpuset) pins the VMM for less run-to-run noise. ----
APPEND_BASE="earlyprintk=ttyS0 console=ttyS0 quiet cyc.dur=$DURATION cyc.load=$CPUS cyc.loadkind=$LOAD"
PINPFX=""
[ -n "${PIN:-}" ] && PINPFX="taskset -c '$PIN' "
chvcmd() { # $1 = kernel, $2 = serial output file, $3 = extra cmdline
	echo "timeout $TIMEOUT ${PINPFX}'$CHV' $CHV_EXTRA_ARGS --kernel '$1' --initramfs '$WORK/initrd.cpio.gz' --cmdline '$APPEND_BASE ${3:-}' --cpus boot=$CPUS --memory size=512M --serial file='$2' --console off"
}

# ---- preflight: confirm a boot actually completes cyclictest, else it is noise ----
eval "$(chvcmd "${KPATH[${ORDER[0]}]}" "$WORK/pre.log" "${ACMD[${ORDER[0]}]}")" >/dev/null 2>&1 || true
grep -q '^CT_DONE=' "$WORK/pre.log" 2>/dev/null || {
	echo "ERROR: boot did not complete cyclictest (no CT_DONE). Serial tail:" >&2
	tail -n 25 "$WORK/pre.log" 2>/dev/null >&2 || true
	exit 4
}

# ---- measure each arm RUNS times ----
declare -A SAMP=()
declare -a METRICS=("min(us)" "avg(us)" "max(us)")
declare -A RTRT=()
for label in "${ORDER[@]}"; do
	echo ">> measuring $label ($RUNS runs, ${CPUS} vCPU, ${DURATION}s) ..." >&2
	r=0
	while [ "$r" -lt "$RUNS" ]; do
		eval "$(chvcmd "${KPATH[$label]}" "$WORK/con.log" "${ACMD[$label]}")" >/dev/null 2>&1 || true
		mn=$(sed -n 's/^CYC_min=//p' "$WORK/con.log" | tail -1 | tr -d '\r')
		av=$(sed -n 's/^CYC_avg=//p' "$WORK/con.log" | tail -1 | tr -d '\r')
		mx=$(sed -n 's/^CYC_max=//p' "$WORK/con.log" | tail -1 | tr -d '\r')
		[ -n "$mn" ] && SAMP["$label|min(us)"]="${SAMP["$label|min(us)"]:-} $mn"
		[ -n "$av" ] && SAMP["$label|avg(us)"]="${SAMP["$label|avg(us)"]:-} $av"
		[ -n "$mx" ] && SAMP["$label|max(us)"]="${SAMP["$label|max(us)"]:-} $mx"
		r=$((r + 1))
	done
	RTRT[$label]=$(sed -n 's/^RT_realtime=//p' "$WORK/con.log" | tail -1 | tr -d '\r')
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
echo
echo "== cyclictest: wake-up latency in microseconds under load, lower is better =="
echo "   N=$RUNS boots/arm, ${CPUS} vCPU, ${DURATION}s, prio 99, load=$LOAD; delta% vs '$base_label'"
echo
printf '%-22s' "metric"
for label in "${ORDER[@]}"; do printf '%-28s' "$label"; done
echo
for metric in "${METRICS[@]}"; do
	printf '%-22s' "$metric"
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
echo "== in-guest RT state (PREEMPT_RT in uname, last run) =="
for label in "${ORDER[@]}"; do
	printf '%-22s realtime=%s\n' "$label" "${RTRT[$label]:-?}"
done
for label in "${ORDER[@]}"; do
	[ "${label%%:*}" = "zone-rt" ] || continue
	[ "${RTRT[$label]:-0}" = "1" ] ||
		echo "WARNING: $label does not report a PREEMPT_RT kernel (realtime='${RTRT[$label]:-}'); the fragment may not have taken -- check 'zcat target/config.gz | grep PREEMPT_RT'." >&2
done
