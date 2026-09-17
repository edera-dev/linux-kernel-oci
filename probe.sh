#!/bin/bash
# Check whether published Edera kernel images actually carry patches/.
#
# Our patches add string literals and symbol names that pristine upstream does
# not have. Both survive into the bzImage -- strings in .rodata, symbols in the
# kallsyms blob -- so grepping a decompressed vmlinux tells you whether the
# patch series was applied. See the "Probe table" comment below for how a probe
# earns its place here.
#
# Usage:
#   probe.sh [-v] image   REF...            an OCI ref (tag or digest)
#   probe.sh [-v] release REF...            a protect git ref; expands to the
#                                           kernels that ref pins
#   probe.sh [-v] range   IMAGE [REGEX]     every tag of IMAGE matching REGEX
#
# Examples:
#   probe.sh release v1.12.5 v1.12.4
#   probe.sh range zone-kernel '^6\.18\.(4[4-9]|5[0-9])$'
#   probe.sh -v image ghcr.io/edera-dev/zone-nvidiagpu-kernel:6.18.52-nvidia-610.57.04
#
# Exit status is nonzero if any image came back UNPATCHED, so this can gate CI.
#
# Needs: crane, gh, and a linux source tree for scripts/extract-vmlinux.
set -euo pipefail

LINUX_TREE="${LINUX_TREE:-${HOME}/edera/linux-zone}"
EXTRACT="${LINUX_TREE}/scripts/extract-vmlinux"
PROTECT_REPO="${PROTECT_REPO:-edera-dev/protect}"
KERNEL_NS="${KERNEL_NS:-ghcr.io/edera-dev}"
PLATFORM="${PLATFORM:-linux/amd64}"
# Keyed by digest, so the cache is content-addressed and never goes stale.
CACHE="${CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/edera-kernel-probe}"
VERBOSE=0

# Probe table: scope|status|label|regex
#
# scope   all  = every flavor | zone = zone* only | host = host only,
#                optionally suffixed /<arch> to limit it to one KERNEL_ARCH.
#                Scope matters: xen-netback lives only in a dom0 kernel, the
#                9p client only in a guest, and the Xen NUMA and pv-iommu work
#                is x86-only, so "absent" is meaningless outside the flavors
#                and arches that build the code. Verified by probing a
#                known-patched arm64 build: the four /x86_64 probes are absent
#                there too, so they are an arch property, not a defect.
# status  core   = the patch has been in patches/ long enough that every image
#                  still in circulation should carry it. Counts toward the
#                  verdict.
#         recent = the patch joined patches/ recently, so an older image can
#                  lack it legitimately. Reported separately as "(+n/m recent)"
#                  and never produces UNPATCHED. Move one to core once no
#                  image predating the patch is still in use.
#
# Every probe below is validated: it fires on at least one known-patched build
# and on none of the 2026-09-15 builds, which were pristine upstream. Firing on
# nothing means undetectable (inlined or config-gated); firing on the unpatched
# build means it is an upstream string, not one of ours. Both get dropped --
# "Issue one hypercall per page" (pv-iommu/0008) went the first way.
#
# Adding a probe: prefer a string literal over a symbol. A static function can
# be inlined out of the symbol table (p9_client_find_shared, setup_netfront_split
# and gntdev_relocate_map all vanish this way), but a printk format string has
# to survive for the call site to reference it. Anchor symbol probes that are a
# substring of an upstream name -- a bare balloon_oom_notify also matches
# upstream's virtio_balloon_oom_notify.
PROBES=(
	"all/x86_64|core|0002-xen-add-xen_mfn_to_node [str]|XENMEM_get_mfn_pxms unavailable"
	"all/x86_64|core|0002-xen-add-xen_mfn_to_node [sym]|xen_mfn_to_node"
	"all/x86_64|core|0003-unpopulated-pages-numa [sym]|xen_alloc_unpopulated_pages_node"
	"all|core|0004-grant-table-alloc-node [sym]|gnttab_alloc_pages_node"
	"all|core|0005-events-lateeoi-on-node [sym]|bind_evtchn_to_irq_lateeoi_on_node"
	"all|core|0006-xenbus-home-ring [sym]|xenbus_ring_host_node"
	"all|core|0007-xenbus-setup-ring-node [sym]|xenbus_setup_ring_node"
	"all|core|0010-xen-netfront-per-queue [str]|XPS setup failed for queue"
	"all/x86_64|core|0012-xen-gntdev-home-map [str]|relocate remap on node"
	"all|core|0001-xen-deflate-balloon-oom [sym]|[^a-zA-Z0-9_]balloon_oom_notify"
	"zone|core|0001-xen-evtchn-diagnose [str]|xen-evtchn overflow on"
	"zone|core|9pfs-xen-multi-attach [str]|edera_multi_attach_v1"
	"host|core|0008-xen-netback-per-queue [str]|Could not setup irq handler for"
	"host|core|hyperv-0001-nested-dom0 [str]|nested under Hyper-V, enabling VMBus"
	"host|core|hyperv-0001-nested-dom0 [sym]|hyperv_init_nested_on_xen"
	"host|core|hyperv-0005-vpci-vector [str]|Xen: Hyper-V vPCI interrupts relayed on"
	# pv-iommu joined the series on 2026-09-09; images built before that
	# legitimately lack it.
	"all/x86_64|recent|pv-iommu-0001-driver [str]|Initialising Xen IOMMU driver"
	"all/x86_64|recent|pv-iommu-0001-map-pages [sym]|iommu_xen_map_pages"
	"all/x86_64|recent|pv-iommu-0005-pcifront [sym]|pcifront_machine_sbdf"
)

# Patches this technique cannot see at all: they change behaviour without
# adding a string or a non-inlined symbol. A clean run does NOT vouch for them.
#   0001-x86-CPU-AMD-avoid-printing-reset-reasons-on-Xen-domU  (the panic)
#   0001-x86-topology-Tolerate-lack-of-APIC-when-booting-as-X_03
#   0002-x86-amd_node-fix-integer-divide-by-zero-during-init
#   0003-x86-amd_node-fix-null-pointer-dereference-if-amd_smn
#   0001-xen-xlate_mmu-relocate-remap_pfn-utils, 0002-batch-gfn-mappings
#   0001-drm-virtio-use-the-DMA-API-for-resource-backing-on-X
#   0001-firmware-qemu_fw_cfg-do-not-use-the-DMA-interface-on
#   hack-around-pci-msix-restore-bugs-in-pv-domu
# In practice that is fine: the patch loop is all-or-nothing, so the probes
# above stand in for the whole series.

die() {
	echo "probe.sh: ${1}" >&2
	exit 1
}

usage() {
	sed -n '2,22p' "${0}" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

# Strip any tag or digest, leaving the bare repository.
repo_of() {
	local repo="${1%%@*}"
	case "${repo##*/}" in
	*:*) repo="${repo%:*}" ;;
	esac
	printf '%s' "${repo}"
}

# Accept a bare image name as shorthand for the Edera namespace.
qualify() {
	case "${1}" in
	*/*) printf '%s' "${1}" ;;
	*) printf '%s/%s' "${KERNEL_NS}" "${1}" ;;
	esac
}

# A ref short enough for the table: drop the namespace, abbreviate the digest.
label_of() {
	local short="${1#"${KERNEL_NS}"/}"
	case "${short}" in
	*@sha256:*) printf '%s@%.19s' "${short%%@*}" "${short#*@}" ;;
	*) printf '%.46s' "${short}" ;;
	esac
}

# Download and decompress once per digest; later calls reuse the cache.
# Sets: F_DIGEST F_VMLINUX F_VERSION F_FLAVOR F_ARCH F_BUILT
fetch() {
	local ref repo dir layer
	ref="$(qualify "${1}")"
	repo="$(repo_of "${ref}")"

	F_DIGEST="$(crane digest "${ref}" 2>/dev/null)" || return 1
	# Platform belongs in the key: for a multi-arch tag crane reports the index
	# digest, which is identical for amd64 and arm64, so keying on the digest
	# alone would serve one architecture's vmlinux for the other.
	dir="${CACHE}/${F_DIGEST#sha256:}-${PLATFORM//\//-}"
	F_VMLINUX="${dir}/vmlinux"

	if [ ! -s "${dir}/metadata" ]; then
		mkdir -p "${dir}"
		crane pull --platform "${PLATFORM}" "${repo}@${F_DIGEST}" "${dir}/img.tar" >/dev/null 2>&1 || return 1
		(cd "${dir}" && tar xf img.tar) || return 1
		for layer in "${dir}"/*.tar.gz; do
			tar tzf "${layer}" 2>/dev/null | grep -qx 'kernel/image' &&
				tar xzf "${layer}" -C "${dir}" kernel/image
			tar tzf "${layer}" 2>/dev/null | grep -qx 'kernel/metadata' &&
				tar xzf "${layer}" -C "${dir}" kernel/metadata
		done
		[ -f "${dir}/kernel/image" ] || return 1
		cp "${dir}/kernel/metadata" "${dir}/metadata" 2>/dev/null || : >"${dir}/metadata"
		# arm64 ships an Image, not a self-extracting bzImage; extract-vmlinux
		# cannot open it, and an empty vmlinux would read as UNPATCHED.
		"${EXTRACT}" "${dir}/kernel/image" >"${F_VMLINUX}" 2>/dev/null || :
		file -b "${dir}/kernel/image" | sed -n 's/.*version [^ ]* //;s/,.*//p' >"${dir}/built"
		rm -f "${dir}/img.tar"
	fi

	F_VERSION="$(sed -n 's/^KERNEL_VERSION=//p' "${dir}/metadata")"
	F_FLAVOR="$(sed -n 's/^KERNEL_FLAVOR=//p' "${dir}/metadata")"
	F_ARCH="$(sed -n 's/^KERNEL_ARCH=//p' "${dir}/metadata")"
	F_BUILT="$(cat "${dir}/built" 2>/dev/null)"
	[ -s "${F_VMLINUX}" ]
}

applies() { # $1 = probe scope[/arch], $2 = kernel flavor, $3 = kernel arch
	local want_flavor="${1%%/*}" want_arch=""
	case "${1}" in */*) want_arch="${1#*/}" ;; esac
	[ -z "${want_arch}" ] || [ "${want_arch}" = "${3}" ] || return 1
	case "${want_flavor}" in
	all) return 0 ;;
	zone) case "${2}" in zone*) return 0 ;; esac ;;
	host) [ "${2}" = "host" ] && return 0 ;;
	esac
	return 1
}

FAILED=0

report() { # $1 = display label, $2 = image ref
	local scope status label regex hits total new_hits new_total verdict entry n
	if ! fetch "${2}"; then
		printf '%-46s %-24s %-15s %-8s %s\n' "${1}" "-" "-" "-" "SKIP (unreadable)"
		return
	fi

	hits=0 total=0 new_hits=0 new_total=0
	for entry in "${PROBES[@]}"; do
		IFS='|' read -r scope status label regex <<<"${entry}"
		applies "${scope}" "${F_FLAVOR}" "${F_ARCH}" || continue
		n="$(grep -a -c -E -- "${regex}" "${F_VMLINUX}" 2>/dev/null || true)"
		if [ "${status}" = "recent" ]; then
			new_total=$((new_total + 1))
			[ "${n:-0}" -gt 0 ] && new_hits=$((new_hits + 1))
		else
			total=$((total + 1))
			[ "${n:-0}" -gt 0 ] && hits=$((hits + 1))
		fi
		[ "${VERBOSE}" -eq 1 ] &&
			printf '    %-44s %s%s\n' "${label}" \
				"$([ "${n:-0}" -gt 0 ] && echo PRESENT || echo absent)" \
				"$([ "${status}" = "recent" ] && echo '  (recent)' || echo '')"
	done

	if [ "${hits}" -eq 0 ]; then
		verdict="UNPATCHED"
		FAILED=1
	elif [ "${hits}" -eq "${total}" ]; then
		verdict="OK"
	else
		verdict="PARTIAL"
	fi
	[ "${new_hits}" -gt 0 ] && verdict="${verdict} (+${new_hits}/${new_total} recent)"

	printf '%-46s %-24s %-15s %-8s %s\n' \
		"${1}" "${F_VERSION}" "${F_FLAVOR}" "${hits}/${total}" "${verdict}"
	[ "${VERBOSE}" -eq 1 ] && printf '    built %s  %s\n\n' "${F_BUILT}" "${F_DIGEST}"
	return 0
}

header() {
	printf '%-46s %-24s %-15s %-8s %s\n' "image" "version" "flavor" "probes" "verdict"
	printf '%-46s %-24s %-15s %-8s %s\n' \
		"$(printf '%.0s-' {1..46})" "$(printf '%.0s-' {1..24})" \
		"$(printf '%.0s-' {1..15})" "$(printf '%.0s-' {1..8})" "-------"
}

# Read a file out of the protect repo at an arbitrary git ref.
protect_file() {
	gh api "repos/${PROTECT_REPO}/contents/${1}?ref=${2}" --jq '.content' 2>/dev/null | base64 -d
}

cmd_image() {
	header
	for ref in "$@"; do report "$(label_of "$(qualify "${ref}")")" "${ref}"; done
}

cmd_release() {
	local ref line
	for ref in "$@"; do
		echo "=== ${PROTECT_REPO} @ ${ref} ==="
		header
		# Dockerfile pins carry their own digest; manifest pins are tags that
		# hack/ci/resolve-digests.sh turns into digests at release build time,
		# so resolving them here mirrors what the installer embeds.
		for line in \
			"$(protect_file images/Dockerfile.zone "${ref}" | sed -n 's/^FROM \([^ ]*zone-kernel[^ ]*\).*/\1/p' | head -1)" \
			"$(protect_file images/Dockerfile.host-kernel "${ref}" | sed -n 's/^FROM \([^ ]*host-kernel[^ ]*\).*/\1/p' | head -1)" \
			$(protect_file manifest "${ref}" | sed -n 's/^REPO_ZONE_KERNEL_[A-Z]*="\(.*\)"$/\1/p'); do
			[ -n "${line}" ] || continue
			report "$(label_of "${line}")" "${line}"
		done
		echo
	done
}

cmd_range() {
	local image regex tags tag
	image="$(qualify "${1:?usage: probe.sh range IMAGE [REGEX]}")"
	regex="${2:-.}"
	tags="$(crane ls "${image}" 2>/dev/null | grep -E "${regex}" | sort -V)" ||
		die "no tags of ${image} matched ${regex}"
	[ -n "${tags}" ] || die "no tags of ${image} matched ${regex}"
	header
	for tag in ${tags}; do
		report "$(label_of "${image}:${tag}")" "${image}:${tag}"
	done
}

if [ "${1:-}" = "-v" ]; then
	VERBOSE=1
	shift
fi
[ $# -ge 1 ] || usage 1
[ -x "${EXTRACT}" ] || die "no extract-vmlinux at ${EXTRACT} (set LINUX_TREE)"
command -v crane >/dev/null || die "crane not on PATH"

gh auth token 2>/dev/null | crane auth login ghcr.io -u "$(gh api user --jq .login 2>/dev/null)" --password-stdin >/dev/null 2>&1 || :

# Dispatched explicitly rather than through "cmd_${1}": an indirect call makes
# every function below look unreachable to shellcheck.
SUB="${1}"
shift
case "${SUB}" in
image) cmd_image "$@" ;;
release) cmd_release "$@" ;;
range) cmd_range "$@" ;;
-h | --help) usage ;;
*) usage 1 ;;
esac

exit "${FAILED}"
