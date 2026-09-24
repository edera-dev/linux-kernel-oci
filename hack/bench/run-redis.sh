#!/usr/bin/env bash
#
# Run redis-benchmark against redis-server inside a zone kernel under Cloud Hypervisor and
# compare requests-per-sec across kernel arms + sysctl profiles. Like run-pgbench.sh this
# needs a real rootfs, not a static binary: the initramfs IS the redis:alpine OCI image
# (podman export -> cpio) with a custom /init that starts redis-server, runs redis-benchmark,
# prints REDIS_<op>_rps, and powers off. The rootfs is kernel-independent -- built once,
# reused across every arm.
#
# Localhost bench: server and client both in-guest talking over 127.0.0.1. Real TCP stack,
# so most net.core.* and net.ipv4.* sysctls actually apply (accept queues, port range,
# tw_reuse, buffer sizes). What loopback does NOT exercise: NIC RX queue
# (net.core.netdev_max_backlog) and congestion-control algorithm. A two-guest tap+bridge
# harness would close that gap; that needs /dev/net/tun exposed, which the sandbox doesn't.
#
# Default arms probe two orthogonal levers: mitigations=off flag (redis is very syscall-heavy)
# and prof=mq (network buffer / accept-queue sysctls). -k 0 (new connection per request) is
# used so port range + tw_reuse + accept queue are actually stressed.
#
# Lives in hack/bench/; kernel-oci repo root is derived from this script's location.
# x86_64 only. Needs: docker (buildx), podman (+ curl if fetching CHV). /dev/kvm required
# (or SKIP_KVM_CHECK=1 if going via chv-wrap-run.sh).
#
# Usage:
#   hack/bench/run-redis.sh                                     # default 4-arm comparison
#   RUNS=30 hack/bench/run-redis.sh
#   FLAVORS="zone zone:prof=mq zone:mitigations=off" hack/bench/run-redis.sh
#   NREQ=100000 CLIENTS=100 KEEPALIVE=1 hack/bench/run-redis.sh
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
FLAVORS="${FLAVORS:-zone zone:prof=mq zone:mitigations=off zone:mitigations=off,prof=mq}"
REGISTRY="${REGISTRY:-127.0.0.1:5000}"
REG_NAME="${REG_NAME:-edera-local-registry}"
CPUS="${CPUS:-8}"
MEM="${MEM:-1024M}"
NREQ="${NREQ:-50000}"
CLIENTS="${CLIENTS:-50}"
KEEPALIVE="${KEEPALIVE:-0}"
TIMEOUT="${TIMEOUT:-300}"
REDIS_IMAGE="${REDIS_IMAGE:-docker.io/library/redis:alpine}"
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

# ---- Redis-rootfs initramfs (kernel-independent, built once): a /init starts redis-server,
# waits, runs redis-benchmark, prints REDIS_<op>_rps, powers off. redis-benchmark parameters
# arrive on the kernel cmdline (r.*); prof= is parsed the same way as the other benches. ----
INIT_B64=$(
	base64 -w0 <<'EOF'
#!/bin/sh
mount -t proc none /proc 2>/dev/null
mount -t sysfs none /sys 2>/dev/null
mount -t devtmpfs none /dev 2>/dev/null
mount -t tmpfs none /tmp 2>/dev/null
mount -t tmpfs none /run 2>/dev/null
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# Bring loopback up -- alpine's default init would do this via a service; here we boot
# with a bare /init and must do it ourselves, otherwise redis-cli/-benchmark on 127.0.0.1
# fails "Network unreachable".
ip link set lo up 2>/dev/null || ifconfig lo up 2>/dev/null || true
echo "R_uname=$(uname -a)"
NREQ=$(sed -n 's/.*r\.nreq=\([0-9]*\).*/\1/p' /proc/cmdline); NREQ=${NREQ:-50000}
CL=$(sed -n 's/.*r\.clients=\([0-9]*\).*/\1/p' /proc/cmdline); CL=${CL:-50}
KA=$(sed -n 's/.*r\.keepalive=\([01]\).*/\1/p' /proc/cmdline); KA=${KA:-0}
PROF=$(sed -n 's/.*prof=\([a-z-]*\).*/\1/p' /proc/cmdline)
case "$PROF" in
mq)
echo 65535 > /proc/sys/net/core/somaxconn 2>/dev/null
echo 65535 > /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null
echo "1024	65535" > /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null
echo 1 > /proc/sys/net/ipv4/tcp_tw_reuse 2>/dev/null
echo 134217728 > /proc/sys/net/core/rmem_max 2>/dev/null
echo 134217728 > /proc/sys/net/core/wmem_max 2>/dev/null
echo 5000 > /proc/sys/net/core/netdev_max_backlog 2>/dev/null
echo 2097152 > /proc/sys/fs/file-max 2>/dev/null
echo 0 > /proc/sys/net/ipv4/tcp_slow_start_after_idle 2>/dev/null
;;
esac
echo "PROF=${PROF:-none}"
echo "APPLIED_somaxconn=$(cat /proc/sys/net/core/somaxconn 2>/dev/null)"
echo "APPLIED_syn_backlog=$(cat /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null)"
echo "APPLIED_port_range=$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null | tr -d '\t')"
echo "APPLIED_tw_reuse=$(cat /proc/sys/net/ipv4/tcp_tw_reuse 2>/dev/null)"
echo "APPLIED_rmem_max=$(cat /proc/sys/net/core/rmem_max 2>/dev/null)"
echo "APPLIED_wmem_max=$(cat /proc/sys/net/core/wmem_max 2>/dev/null)"
echo "APPLIED_file_max=$(cat /proc/sys/fs/file-max 2>/dev/null)"

# Start redis-server as a daemon, bound to localhost, no persistence.
redis-server --daemonize yes --save "" --appendonly no --protected-mode no \
    --bind 127.0.0.1 --port 6379 --tcp-backlog 65535 >/tmp/redis.log 2>&1
i=0
while [ $i -lt 30 ]; do
    if redis-cli -h 127.0.0.1 -p 6379 ping 2>/dev/null | grep -q PONG; then break; fi
    i=$((i + 1)); sleep 0.2
done
echo "REDIS_UP=$(redis-cli -h 127.0.0.1 -p 6379 ping 2>/dev/null)"

# -k 0 = new TCP connection per request (stresses accept queue, port range, tw_reuse).
# -k 1 = keepalive (tests buffer sizes + steady-state throughput).
KA_ARG=""
[ "$KA" = "0" ] && KA_ARG="-k 0"
[ "$KA" = "1" ] && KA_ARG="-k 1"
# --csv output is one final line per op: "SET","12345.67" -- stable across versions
# and doesn't have the -q format's cursor-move progress lines that break line parsing.
out=$(redis-benchmark -h 127.0.0.1 -p 6379 -c "$CL" -n "$NREQ" -t SET,GET,LPUSH,LPOP $KA_ARG --csv 2>&1)
echo "$out" | while IFS=, read -r c1 c2 _rest; do
    op=$(echo "$c1" | tr -d '"')
    rps=$(echo "$c2" | tr -d '"')
    case "$op" in
    SET|GET|LPUSH|LPOP)
        [ -n "$rps" ] && echo "REDIS_${op}_rps=$rps"
        ;;
    esac
done
echo "R_DONE=1"
echo o >/proc/sysrq-trigger 2>/dev/null
sleep 10
EOF
)
echo ">> building Redis initramfs from $REDIS_IMAGE (once) ..." >&2
R_CID="$(podman create "$REDIS_IMAGE")" || {
	echo "ERROR: could not create a container from $REDIS_IMAGE" >&2
	exit 3
}
echo "   WORK=$WORK" >&2
# Stage 1: dump the image rootfs to a tar file (podman export handles hardlinks
# consistently, unlike bare `tar` invocations here).
podman export "$R_CID" >"$WORK/rootfs.tar" 2>"$WORK/initramfs.err" || {
	podman rm -f "$R_CID" >/dev/null 2>&1 || true
	echo "ERROR: podman export failed:" >&2
	cat "$WORK/initramfs.err" >&2
	exit 4
}
# Stage 2: extract, inject /init, repack as cpio.gz in the pre-built kernel-builder
# image (has GNU tar+cpio+gzip baked in -- apt at run-time is blocked in this sandbox).
# GNU tar unpacks alpine tzdata hardlinks further than busybox tar. --skip-old-files
# sidesteps EXDEV / permission blips on entries redis does not need.
BUILDER_IMG="${BUILDER_IMG:-edera-kernel-builder}"
if ! podman run --rm -i --user 0 -v "$WORK":"$WORK" \
	"$BUILDER_IMG" sh -c '
	set -e
	R=/tmp/root; mkdir -p "$R"
	tar -x -f '"$WORK/rootfs.tar"' -C "$R" --skip-old-files 2>/dev/null || true
	echo '"$INIT_B64"' | base64 -d > "$R/init"; chmod +x "$R/init"
	cd "$R" && find . | cpio -o -H newc 2>/dev/null | gzip -1
' >"$WORK/initrd.cpio.gz" 2>>"$WORK/initramfs.err"; then
	podman rm -f "$R_CID" >/dev/null 2>&1 || true
	echo "ERROR: redis initramfs build failed:" >&2
	echo "  --- rootfs.tar size: $(stat -c %s "$WORK/rootfs.tar" 2>/dev/null || echo n/a) ---" >&2
	echo "  --- initramfs.err: ---" >&2
	cat "$WORK/initramfs.err" >&2
	echo "  --- initrd.cpio.gz size: $(stat -c %s "$WORK/initrd.cpio.gz" 2>/dev/null || echo n/a) ---" >&2
	echo "  --- WORK contents: ---" >&2
	ls -la "$WORK" >&2
	exit 4
fi
podman rm -f "$R_CID" >/dev/null 2>&1 || true
[ -s "$WORK/initrd.cpio.gz" ] || {
	echo "ERROR: empty redis initramfs" >&2
	exit 4
}

APPEND_BASE="earlyprintk=ttyS0 console=ttyS0 quiet r.nreq=$NREQ r.clients=$CLIENTS r.keepalive=$KEEPALIVE"
PINPFX=""
[ -n "${PIN:-}" ] && PINPFX="taskset -c '$PIN' "
chvcmd() { # $1 = kernel, $2 = serial output file, $3 = extra cmdline
	echo "timeout $TIMEOUT ${PINPFX}'$CHV' $CHV_EXTRA_ARGS --kernel '$1' --initramfs '$WORK/initrd.cpio.gz' --cmdline '$APPEND_BASE ${3:-}' --cpus boot=$CPUS --memory size=$MEM --serial file='$2' --console off"
}

# ---- preflight ----
eval "$(chvcmd "${KPATH[${ORDER[0]}]}" "$WORK/pre.log" "${ACMD[${ORDER[0]}]}")" >/dev/null 2>&1 || true
grep -q '^R_DONE=' "$WORK/pre.log" 2>/dev/null || {
	echo "ERROR: boot did not complete redis-benchmark (no R_DONE). Serial tail:" >&2
	tail -n 25 "$WORK/pre.log" 2>/dev/null >&2 || true
	exit 4
}

# ---- measure each arm RUNS times ----
declare -A SAMP=()
declare -a METRICS=("SET" "GET" "LPUSH" "LPOP")
for label in "${ORDER[@]}"; do
	echo ">> measuring $label ($RUNS runs, ${CPUS} vCPU, n=$NREQ c=$CLIENTS k=$KEEPALIVE) ..." >&2
	r=0
	while [ "$r" -lt "$RUNS" ]; do
		eval "$(chvcmd "${KPATH[$label]}" "$WORK/con.log" "${ACMD[$label]}")" >/dev/null 2>&1 || true
		for op in "${METRICS[@]}"; do
			v=$(sed -n "s/^REDIS_${op}_rps=//p" "$WORK/con.log" | tail -1 | tr -d '\r')
			[ -n "$v" ] && SAMP["$label|$op"]="${SAMP["$label|$op"]:-} $v"
		done
		r=$((r + 1))
	done
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
echo "== redis-benchmark: requests/sec, HIGHER is better (N=$RUNS boots/arm) =="
echo "   ${CPUS} vCPU, n=$NREQ c=$CLIENTS keepalive=$KEEPALIVE; delta% vs '$base_label'"
echo
printf '%-8s' "op"
for label in "${ORDER[@]}"; do printf '%-30s' "$label"; done
echo
for op in "${METRICS[@]}"; do
	printf '%-8s' "$op"
	bm=""
	mean_of "$base_label|$op" && bm="$MO_M"
	for label in "${ORDER[@]}"; do
		if mean_of "$label|$op"; then
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
