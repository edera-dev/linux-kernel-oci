#!/usr/bin/env bash
#
# Run pgbench (PostgreSQL) inside a zone kernel under Cloud Hypervisor and compare TPS across
# kernel arms. Unlike the other bench scripts this needs a real rootfs, not a static binary:
# the initramfs IS a Postgres OCI image (podman export -> cpio) with a custom /init that runs
# initdb + pgbench and prints TPS (HIGHER is better). The rootfs is kernel-independent, so it
# is built once and reused across every arm.
#
# The point of this axis: a database is syscall/IO/memory heavy, and its big kernel lever is
# mitigations posture -- a boot flag, not an image. So the default arms include zone:mitigations=off
# and zone-db:mitigations=off to show the flag (not the zone-db image) is what moves TPS. Each
# FLAVORS entry is <flavor>[:<extra-cmdline>].
#
# NOTE: edera-benchmarks-pts runs PTS in a container on the HOST kernel, so it cannot compare
# zone kernel flavors; this script boots the workload on the actual zone kernel instead.
#
# Lives in hack/bench/; repo root is derived from this script's location. Uses upstream
# cloud-hypervisor (set CHV=/path or have it on PATH, else fetched to KCACHE). Needs /dev/kvm.
# x86_64 only. Needs: docker (buildx), podman (+ curl if fetching CHV). The zone kernel needs
# CONFIG_MAGIC_SYSRQ for the clean poweroff (the TIMEOUT is a backstop otherwise).
#
# Usage:
#   hack/bench/run-pgbench.sh                              # zone vs zone-db vs mitigations flag
#   SCALE=50 DURATION=60 CLIENTS=16 hack/bench/run-pgbench.sh
#   FLAVORS="zone zone-db zone-lto" KVER=6.18.52 hack/bench/run-pgbench.sh
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
FLAVORS="${FLAVORS:-zone zone-db zone:mitigations=off zone-db:mitigations=off zone-lto}"
REGISTRY="${REGISTRY:-127.0.0.1:5000}"
REG_NAME="${REG_NAME:-edera-local-registry}"
CPUS="${CPUS:-8}"
MEM="${MEM:-4096M}"
SCALE="${SCALE:-10}"
DURATION="${DURATION:-30}"
CLIENTS="${CLIENTS:-8}"
TIMEOUT="${TIMEOUT:-$((DURATION + 240))}"
PG_IMAGE="${PG_IMAGE:-docker.io/library/postgres:16}"
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

# ---- Postgres-rootfs initramfs (kernel-independent, built once): a /init runs initdb +
# pgbench and prints TPS. pgbench parameters arrive on the kernel cmdline (pgb.*). Postgres
# refuses to run as root, so gosu drops to the postgres user; the whole rootfs is a writable
# tmpfs so PGDATA/sockets just work. ----
INIT_B64=$(
	base64 -w0 <<'EOF'
#!/bin/sh
mount -t proc none /proc 2>/dev/null
mount -t sysfs none /sys 2>/dev/null
mount -t devtmpfs none /dev 2>/dev/null
mount -t tmpfs none /tmp 2>/dev/null
mount -t tmpfs none /run 2>/dev/null
echo "PG_uname=$(uname -a)"
SCALE=$(sed -n 's/.*pgb\.scale=\([0-9]*\).*/\1/p' /proc/cmdline); SCALE=${SCALE:-10}
DUR=$(sed -n 's/.*pgb\.dur=\([0-9]*\).*/\1/p' /proc/cmdline); DUR=${DUR:-30}
CL=$(sed -n 's/.*pgb\.clients=\([0-9]*\).*/\1/p' /proc/cmdline); CL=${CL:-8}
PROF=$(sed -n 's/.*prof=\([a-z-]*\).*/\1/p' /proc/cmdline)
case "$PROF" in
db)
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
echo 1 > /proc/sys/vm/swappiness 2>/dev/null
echo 5 > /proc/sys/vm/dirty_background_ratio 2>/dev/null
echo 10 > /proc/sys/vm/dirty_ratio 2>/dev/null
;;
db-thponly)
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
;;
esac
echo "PROF=${PROF:-none}"
echo "APPLIED_thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
echo "APPLIED_thp_defrag=$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null)"
echo "APPLIED_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null)"
echo "APPLIED_dirty_bg=$(cat /proc/sys/vm/dirty_background_ratio 2>/dev/null)"
echo "APPLIED_dirty_ratio=$(cat /proc/sys/vm/dirty_ratio 2>/dev/null)"
PGBIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | tail -1)"
export PATH="$PGBIN:/usr/local/bin:/usr/bin:/bin"
export PGDATA=/pgdata
mkdir -p /pgdata /run/postgresql
chown -R postgres:postgres /pgdata /run/postgresql
gosu postgres initdb -D /pgdata -A trust >/dev/null 2>&1
gosu postgres pg_ctl -D /pgdata -o "-c fsync=off -c shared_buffers=512MB -c unix_socket_directories=/tmp -c listen_addresses=''" -w start >/dev/null 2>&1
gosu postgres createdb -h /tmp bench >/dev/null 2>&1
gosu postgres pgbench -h /tmp -i -s "$SCALE" bench >/dev/null 2>&1
out="$(gosu postgres pgbench -h /tmp -c "$CL" -j "$CL" -T "$DUR" bench 2>&1)"
echo "PGB_tps=$(echo "$out" | sed -n 's/^tps = \([0-9.]*\).*/\1/p' | tail -1)"
echo "PGB_DONE=1"
echo o >/proc/sysrq-trigger 2>/dev/null
sleep 10
EOF
)
echo ">> building Postgres initramfs from $PG_IMAGE (once) ..." >&2
PG_CID="$(podman create "$PG_IMAGE")" || {
	echo "ERROR: could not create a container from $PG_IMAGE" >&2
	exit 3
}
# Export the image rootfs, inject /init, repack as a newc cpio the kernel boots as its root.
if ! podman export "$PG_CID" | podman run --rm -i docker.io/library/busybox:musl sh -c '
	set -e; R=/tmp/root; mkdir -p "$R"; tar -x -C "$R"
	echo '"$INIT_B64"' | base64 -d > "$R/init"; chmod +x "$R/init"
	cd "$R" && find . | cpio -o -H newc 2>/dev/null | gzip -1
' >"$WORK/initrd.cpio.gz" 2>"$WORK/initramfs.err"; then
	podman rm -f "$PG_CID" >/dev/null 2>&1 || true
	echo "ERROR: postgres initramfs build failed:" >&2
	cat "$WORK/initramfs.err" >&2
	exit 4
fi
podman rm -f "$PG_CID" >/dev/null 2>&1 || true
[ -s "$WORK/initrd.cpio.gz" ] || {
	echo "ERROR: empty postgres initramfs" >&2
	exit 4
}

# ---- cloud-hypervisor PVH boot; the Postgres rootfs is the initramfs, no extra disk. ----
APPEND_BASE="earlyprintk=ttyS0 console=ttyS0 quiet pgb.scale=$SCALE pgb.dur=$DURATION pgb.clients=$CLIENTS"
PINPFX=""
[ -n "${PIN:-}" ] && PINPFX="taskset -c '$PIN' "
chvcmd() { # $1 = kernel, $2 = serial output file, $3 = extra cmdline
	echo "timeout $TIMEOUT ${PINPFX}'$CHV' $CHV_EXTRA_ARGS --kernel '$1' --initramfs '$WORK/initrd.cpio.gz' --cmdline '$APPEND_BASE ${3:-}' --cpus boot=$CPUS --memory size=$MEM --serial file='$2' --console off"
}

# ---- preflight: confirm a boot actually completes pgbench, else it is noise ----
eval "$(chvcmd "${KPATH[${ORDER[0]}]}" "$WORK/pre.log" "${ACMD[${ORDER[0]}]}")" >/dev/null 2>&1 || true
grep -q '^PGB_DONE=' "$WORK/pre.log" 2>/dev/null || {
	echo "ERROR: boot did not complete pgbench (no PGB_DONE). Serial tail:" >&2
	tail -n 25 "$WORK/pre.log" 2>/dev/null >&2 || true
	exit 4
}

# ---- measure each arm RUNS times ----
declare -A SAMP=()
declare -a METRICS=("tps")
for label in "${ORDER[@]}"; do
	echo ">> measuring $label ($RUNS runs, ${CPUS} vCPU, scale=$SCALE ${DURATION}s c=$CLIENTS) ..." >&2
	r=0
	while [ "$r" -lt "$RUNS" ]; do
		eval "$(chvcmd "${KPATH[$label]}" "$WORK/con.log" "${ACMD[$label]}")" >/dev/null 2>&1 || true
		tps=$(sed -n 's/^PGB_tps=//p' "$WORK/con.log" | tail -1 | tr -d '\r')
		[ -n "$tps" ] && SAMP["$label|tps"]="${SAMP["$label|tps"]:-} $tps"
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
echo "== pgbench: TPS, HIGHER is better (N=$RUNS boots/arm) =="
echo "   ${CPUS} vCPU, scale=$SCALE, ${DURATION}s, clients=$CLIENTS; delta% vs '$base_label' (positive = more)"
echo
printf '%-8s' "metric"
for label in "${ORDER[@]}"; do printf '%-30s' "$label"; done
echo
for metric in "${METRICS[@]}"; do
	printf '%-8s' "$metric"
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
