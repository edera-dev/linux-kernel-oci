#!/usr/bin/env bash
#
# Compare the OCI kernel payload size across flavors: bzImage (kernel) + config.gz
# + addons.squashfs (modules) + metadata. Builds each flavor and reads the repo's
# target/, which docker-build.sh bind-mounts, so no push/pull. Sizes are ~= the
# registry pull size (kernel, squashfs, and config.gz are already compressed).
#
# Lives in hack/bench/; the repo root is derived from this script's location, so it
# runs from any working directory. Needs docker (buildx).
#
# Usage:  hack/bench/compare-kernel-size.sh                    # zone vs zone-tiny, 6.18
#         FLAVORS="zone zone-tiny" SERIES=6.18 hack/bench/compare-kernel-size.sh
set -euo pipefail

BENCH_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_REPO="${KERNEL_REPO:-$(cd -- "$BENCH_DIR/../.." && pwd)}"
ARCH="${ARCH:-x86_64}"
SERIES="${SERIES:-6.18}"
FLAVORS="${FLAVORS:-zone zone-tiny}"
REGISTRY="${REGISTRY:-127.0.0.1:5000}"           # build target, so we never touch ghcr
REG_NAME="${REG_NAME:-edera-local-registry}"
# no sccache backend locally, and its wrapper can fail the kernel assembler probe
export KERNEL_DISABLE_SCCACHE="${KERNEL_DISABLE_SCCACHE-1}"

cd "$KERNEL_REPO"
mb()   { awk -v b="${1:-0}" 'BEGIN { printf "%.3f", b / 1048576 }'; }
fsize() { stat -c %s "$1" 2>/dev/null || echo 0; }

# local registry so a publish flavor build doesn't try to reach ghcr
docker container inspect "$REG_NAME" >/dev/null 2>&1 ||
	docker run -d --name "$REG_NAME" --restart=unless-stopped \
		-p 127.0.0.1:5000:5000 docker.io/library/registry:2 >/dev/null

cp config.yaml config.yaml.sizebak
trap 'mv -f "$KERNEL_REPO/config.yaml.sizebak" "$KERNEL_REPO/config.yaml" 2>/dev/null || true' EXIT
sed -i "s|^imageNameFormat:.*|imageNameFormat: \"${REGISTRY}/edera-dev/[image]:[tag]\"|" config.yaml

printf '\n%-12s %10s %10s %9s %9s %11s\n' FLAVOR KERNEL ADDONS CONFIG META 'TOTAL(MB)'
printf -- '---------------------------------------------------------------------\n'
declare -A TOT
for f in $FLAVORS; do
	docker buildx rm edera >/dev/null 2>&1 || true
	if ! KERNEL_ARCHITECTURES="$ARCH" ./hack/build/docker-build.sh \
		"stable:flavor=${f};series=${SERIES}" >"/tmp/ksize-${f}.log" 2>&1; then
		printf '%-12s  BUILD FAILED (see /tmp/ksize-%s.log)\n' "$f" "$f"
		continue
	fi
	k=$(fsize target/kernel)
	a=$(fsize target/addons.squashfs)
	c=$(fsize target/config.gz)
	m=$(fsize target/metadata)
	t=$((k + a + c + m))
	TOT[$f]=$t
	printf '%-12s %10s %10s %9s %9s %11s\n' \
		"$f" "$(mb "$k")" "$(mb "$a")" "$(mb "$c")" "$(mb "$m")" "$(mb "$t")"
done

# shellcheck disable=SC2086
set -- $FLAVORS
if [ "$#" -eq 2 ] && [ -n "${TOT[$1]:-}" ] && [ -n "${TOT[$2]:-}" ]; then
	d=$((TOT[$1] - TOT[$2]))
	base=$((TOT[$1] > 0 ? TOT[$1] : 1))
	printf '\ndelta %s -> %s:  %s MB smaller  (%d%%)\n' \
		"$1" "$2" "$(mb "$d")" "$((d * 100 / base))"
fi
