#!/usr/bin/env bash
#
# Run fio inside a zone kernel under Cloud Hypervisor against a scratch virtio-blk disk,
# comparing I/O throughput across kernel arms and I/O schedulers. Builds/caches a bzImage per
# base flavor under KCACHE, embeds a static fio in a busybox initramfs, attaches a raw scratch
# disk (guest /dev/vda), boots each arm N times, and reports IOPS + bandwidth (HIGHER is better).
#
# The point of this axis: in a virtio guest the host arbitrates real disk I/O and the guest
# block scheduler is a runtime sysfs knob, so the default arms set the scheduler at runtime
# (none/mq-deadline/bfq) on the stock kernel to show the kernel IMAGE is not the lever -- plus
# a zone-io flavor (BFQ removed). Each FLAVORS entry is <flavor>[:<extra-cmdline>]; a
# fio.sched= arm arg selects the in-guest scheduler.
#
# Lives in hack/bench/; repo root is derived from this script's location. Uses upstream
# cloud-hypervisor: set CHV=/path, or have `cloud-hypervisor` on PATH, else the static release
# binary is fetched to KCACHE. Needs /dev/kvm. x86_64 only.
# Needs: docker (buildx), podman (+ curl if fetching CHV). fio is taken from FIO_BIN if set,
# else built static from fio (FIO_REF) in a container.
#
# Usage:
#   hack/bench/run-fio.sh                                  # scheduler comparison, randread
#   RW=randwrite BS=64k RUNTIME=30 hack/bench/run-fio.sh
#   FLAVORS="zone zone-io zone-lto" hack/bench/run-fio.sh  # compare kernels (their default sched)
#   KVER=6.18.52 hack/bench/run-fio.sh                     # pin exact kernel version
#   FIO_BIN=/path/to/static/fio hack/bench/run-fio.sh
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
FLAVORS="${FLAVORS:-zone:fio.sched=none zone:fio.sched=mq-deadline zone:fio.sched=bfq zone-io}"
REGISTRY="${REGISTRY:-127.0.0.1:5000}"
REG_NAME="${REG_NAME:-edera-local-registry}"
CPUS="${CPUS:-8}"
MEM="${MEM:-1024M}"
DISK_SIZE="${DISK_SIZE:-4G}"
RW="${RW:-randread}"
BS="${BS:-4k}"
NUMJOBS="${NUMJOBS:-8}"
RUNTIME="${RUNTIME:-15}"
TIMEOUT="${TIMEOUT:-$((RUNTIME + 120))}"
FIO_REF="${FIO_REF:-fio-3.37}"
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

# ---- static fio: reuse FIO_BIN, else build a fully static fio (psync/sync engines, no libaio
# needed) in a debian container and cache it. ----
F_BIN=""
obtain_fio() {
	if [ -n "${FIO_BIN:-}" ]; then
		[ -x "$FIO_BIN" ] || {
			echo "ERROR: FIO_BIN='$FIO_BIN' is not executable." >&2
			exit 3
		}
		F_BIN="$FIO_BIN"
		return 0
	fi
	local cache="$KCACHE/fio.bin" cid
	if [ -z "${REBUILD:-}" ] && [ -x "$cache" ]; then
		F_BIN="$cache"
		return 0
	fi
	echo ">> building static fio ($FIO_REF) ..." >&2
	cat >"$WORK/Dockerfile.fio" <<EOF
FROM docker.io/library/debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates zlib1g-dev && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${FIO_REF} https://github.com/axboe/fio /fio && cd /fio && ./configure --build-static >/dev/null 2>&1 && make -j"\$(nproc)" >/dev/null 2>&1 && cp /fio/fio /fio.bin
EOF
	if ! docker build -t edera-fio-bench -f "$WORK/Dockerfile.fio" "$WORK" >"/tmp/fio-build.log" 2>&1; then
		echo "   fio build FAILED (see /tmp/fio-build.log)" >&2
		echo "   set FIO_BIN=/path/to/static/fio or a valid FIO_REF." >&2
		exit 3
	fi
	cid="$(docker create edera-fio-bench)" || {
		echo "   docker create failed" >&2
		exit 3
	}
	if ! docker cp "$cid:/fio.bin" "$cache" >/dev/null 2>&1; then
		docker rm -f "$cid" >/dev/null 2>&1 || true
		echo "   could not extract /fio.bin from the image" >&2
		exit 3
	fi
	docker rm -f "$cid" >/dev/null 2>&1 || true
	chmod +x "$cache"
	F_BIN="$cache"
}

# ---- collect arms: each FLAVORS entry is <flavor>[:<extra-cmdline>]; build each distinct
# base flavor once and reuse it across arms that share it ----
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
		# KVER pins an exact kernel version (manual spec); otherwise stable = latest of SERIES.
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

obtain_fio
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

# ---- raw scratch disk the guest sees as /dev/vda ----
truncate -s "$DISK_SIZE" "$WORK/scratch.img"

# ---- initramfs: busybox + static fio + a /init that optionally sets the I/O scheduler on
# /dev/vda, runs fio, prints IOPS/bandwidth, and powers off. fio parameters (rw/bs/runtime/
# numjobs) and the scheduler arrive on the kernel cmdline (fio.*) so the image stays generic. ----
INIT_B64=$(
	base64 -w0 <<'EOF'
#!/bin/sh
mount -t proc none /proc 2>/dev/null
mount -t sysfs none /sys 2>/dev/null
mount -t devtmpfs none /dev 2>/dev/null
echo "CMDLINE=$(cat /proc/cmdline)"
RW=$(sed -n 's/.*fio\.rw=\([a-z]*\).*/\1/p' /proc/cmdline); RW=${RW:-randread}
BS=$(sed -n 's/.*fio\.bs=\([0-9kKmM]*\).*/\1/p' /proc/cmdline); BS=${BS:-4k}
RT=$(sed -n 's/.*fio\.rt=\([0-9]*\).*/\1/p' /proc/cmdline); RT=${RT:-15}
NJ=$(sed -n 's/.*fio\.nj=\([0-9]*\).*/\1/p' /proc/cmdline); NJ=${NJ:-1}
SCHED=$(sed -n 's/.*fio\.sched=\([a-z-]*\).*/\1/p' /proc/cmdline)
if [ -n "$SCHED" ] && [ -w /sys/block/vda/queue/scheduler ]; then
echo "$SCHED" > /sys/block/vda/queue/scheduler 2>/dev/null || true
fi
PROF=$(sed -n 's/.*prof=\([a-z-]*\).*/\1/p' /proc/cmdline)
case "$PROF" in
io)
echo 1024 > /sys/block/vda/queue/nr_requests 2>/dev/null
echo 128 > /sys/block/vda/queue/read_ahead_kb 2>/dev/null
;;
esac
echo "PROF=${PROF:-none}"
echo "SCHED_actual=$(sed -n 's/.*\[\([a-z-]*\)\].*/\1/p' /sys/block/vda/queue/scheduler 2>/dev/null)"
echo "APPLIED_nr_requests=$(cat /sys/block/vda/queue/nr_requests 2>/dev/null)"
echo "APPLIED_read_ahead_kb=$(cat /sys/block/vda/queue/read_ahead_kb 2>/dev/null)"
out="$(/bin/fio --name=b --filename=/dev/vda --direct=1 --ioengine=psync --rw="$RW" --bs="$BS" --numjobs="$NJ" --runtime="$RT" --time_based --group_reporting --minimal 2>/dev/null)"
line="$(echo "$out" | awk -F';' 'NF>=50{print; exit}')"
echo "FIO_iops=$(echo "$line" | awk -F';' '{printf "%d", $8 + $49}')"
echo "FIO_bwkbps=$(echo "$line" | awk -F';' '{printf "%d", $7 + $48}')"
echo "FIO_DONE=1"
poweroff -f
EOF
)
# The fio binary comes in on stdin (not a bind mount): a rootless/SELinux host denies the
# container access to a mounted host file, and building the image entirely in-container is
# how measure-boot-time.sh already avoids that.
if ! podman run --rm -i docker.io/library/busybox:musl sh -c '
	set -e; R=/tmp/r; mkdir -p "$R/bin" "$R/proc" "$R/sys"
	echo '"$INIT_B64"' | base64 -d > "$R/init"; chmod +x "$R/init"
	for a in sh mount poweroff cat sed awk; do ln -sf /bin/busybox "$R/bin/$a"; done
	cp /bin/busybox "$R/bin/busybox"
	cat > "$R/bin/fio"; chmod +x "$R/bin/fio"
	cd "$R" && find . | cpio -o -H newc 2>/dev/null | gzip -9
' <"$F_BIN" >"$WORK/initrd.cpio.gz" 2>"$WORK/initramfs.err"; then
	echo "ERROR: initramfs build failed:" >&2
	cat "$WORK/initramfs.err" >&2
	exit 4
fi
[ -s "$WORK/initrd.cpio.gz" ] || {
	echo "ERROR: empty initrd.cpio.gz:" >&2
	cat "$WORK/initramfs.err" >&2
	exit 4
}

# ---- cloud-hypervisor PVH boot with the scratch disk as /dev/vda; serial -> a file we parse.
# Optional PIN (host cpuset) pins the VMM for less run-to-run noise. ----
APPEND_BASE="earlyprintk=ttyS0 console=ttyS0 quiet fio.rw=$RW fio.bs=$BS fio.rt=$RUNTIME fio.nj=$NUMJOBS"
PINPFX=""
[ -n "${PIN:-}" ] && PINPFX="taskset -c '$PIN' "
chvcmd() { # $1 = kernel, $2 = serial output file, $3 = extra cmdline
	echo "timeout $TIMEOUT ${PINPFX}'$CHV' $CHV_EXTRA_ARGS --kernel '$1' --initramfs '$WORK/initrd.cpio.gz' --disk path='$WORK/scratch.img' --cmdline '$APPEND_BASE ${3:-}' --cpus boot=$CPUS --memory size=$MEM --serial file='$2' --console off"
}

# ---- preflight: confirm a boot actually completes fio, else it is noise ----
eval "$(chvcmd "${KPATH[${ORDER[0]}]}" "$WORK/pre.log" "${ACMD[${ORDER[0]}]}")" >/dev/null 2>&1 || true
grep -q '^FIO_DONE=' "$WORK/pre.log" 2>/dev/null || {
	echo "ERROR: boot did not complete fio (no FIO_DONE). Serial tail:" >&2
	tail -n 25 "$WORK/pre.log" 2>/dev/null >&2 || true
	exit 4
}

# ---- measure each arm RUNS times ----
declare -A SAMP=()
declare -a METRICS=("iops" "bw(KB/s)")
declare -A SCHEDV=()
for label in "${ORDER[@]}"; do
	echo ">> measuring $label ($RUNS runs, ${CPUS} vCPU, $RW bs=$BS ${RUNTIME}s) ..." >&2
	r=0
	while [ "$r" -lt "$RUNS" ]; do
		eval "$(chvcmd "${KPATH[$label]}" "$WORK/con.log" "${ACMD[$label]}")" >/dev/null 2>&1 || true
		io=$(sed -n 's/^FIO_iops=//p' "$WORK/con.log" | tail -1 | tr -d '\r')
		bw=$(sed -n 's/^FIO_bwkbps=//p' "$WORK/con.log" | tail -1 | tr -d '\r')
		[ -n "$io" ] && SAMP["$label|iops"]="${SAMP["$label|iops"]:-} $io"
		[ -n "$bw" ] && SAMP["$label|bw(KB/s)"]="${SAMP["$label|bw(KB/s)"]:-} $bw"
		r=$((r + 1))
	done
	SCHEDV[$label]=$(sed -n 's/^SCHED_actual=//p' "$WORK/con.log" | tail -1 | tr -d '\r')
done

# ---- mean/stddev and delta-% vs the baseline arm (higher is better) ----
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
echo "== fio: $RW bs=$BS numjobs=$NUMJOBS on /dev/vda, HIGHER is better (N=$RUNS boots/arm) =="
echo "   ${CPUS} vCPU, ${RUNTIME}s, --direct=1 psync; delta% vs '$base_label' (positive = more)"
echo
for label in "${ORDER[@]}"; do
	printf '   %-30s scheduler=%s\n' "$label" "${SCHEDV[$label]:-?}"
done
echo
printf '%-12s' "metric"
for label in "${ORDER[@]}"; do printf '%-30s' "$label"; done
echo
for metric in "${METRICS[@]}"; do
	printf '%-12s' "$metric"
	bm=""
	mean_of "$base_label|$metric" && bm="$MO_M"
	for label in "${ORDER[@]}"; do
		if mean_of "$label|$metric"; then
			cell="$(printf '%.0f+-%.0f' "$MO_M" "$MO_SD")"
			if [ "$label" != "$base_label" ] && [ -n "$bm" ] && [ "$bm" != "0.0" ]; then
				pct=$(awk -v a="$MO_M" -v b="$bm" 'BEGIN{printf "%+.1f",(a/b-1)*100}')
				cell="$cell (${pct}%)"
			fi
		else
			cell="n/a"
		fi
		printf '%-30s' "$cell"
	done
	echo
done
