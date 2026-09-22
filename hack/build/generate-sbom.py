#!/usr/bin/env python3
"""Generate a curated CycloneDX SBOM for a published kernel manifest.

The kernel / kernel-SDK images are `FROM scratch` containing only compiled
artifacts, so scanning them yields nothing, and scanning the debian build
container yields hundreds of toolchain/base-OS packages that have no bearing on
the kernel that ships. Instead we describe what actually defines the kernel:

  - the exact commit of the Edera Linux tree it was built from (there is no
    separate patch series: every Edera change is a commit on that branch, so
    the commit is the complete statement of what is in this kernel), and
  - for GPU flavors, the firmware / nvidia module versions baked in.

All of this is architecture-independent -- the same source and module versions
apply to every arch in the manifest -- so a single SBOM correctly describes the
whole multi-arch image and stays correct as new arches (e.g. arm64) are added.
There are deliberately NO per-arch / package filter rules.

Reads from the environment (set by the merge job):
  KERNEL_VERSION     e.g. "6.18.52" or "6.18.52+nvidia-610.43.02"
  KERNEL_FLAVOR      e.g. "zone", "host", "zone-amdgpu", "zone-nvidiagpu"
  KERNEL_SRC_URL     source archive URL for the commit that was built
  KERNEL_SRC_REPO    Edera Linux repository URL
  KERNEL_SRC_REF     branch built, e.g. "edera/6.18-lts"
  KERNEL_SRC_COMMIT  commit built
  FIRMWARE_URL       linux-firmware tarball URL (only used for zone-amdgpu)

Writes sbom.cdx.json (CycloneDX 1.6) in the current directory.

This was created with Claude.
"""

import json
import os
import re


def firmware_version_from_url(url):
    # .../linux-firmware-<ver>.tar.xz
    match = re.search(r"linux-firmware-(.+?)\.tar\.", url or "")
    return match.group(1) if match else None


def main():
    version = os.environ["KERNEL_VERSION"]
    flavor = os.environ["KERNEL_FLAVOR"]
    src_url = os.environ.get("KERNEL_SRC_URL", "")
    src_repo = os.environ.get("KERNEL_SRC_REPO", "")
    src_ref = os.environ.get("KERNEL_SRC_REF", "")
    src_commit = os.environ.get("KERNEL_SRC_COMMIT", "")
    firmware_url = os.environ.get("FIRMWARE_URL", "")

    # Strip any "+nvidia-<ver>" local suffix to get the upstream kernel version.
    kernel_version = version.split("+")[0]

    kernel_ref = "pkg:generic/linux@%s" % kernel_version
    linux_component = {
        "bom-ref": kernel_ref,
        "type": "operating-system",
        "name": "linux",
        "version": kernel_version,
        "purl": kernel_ref,
    }
    external_references = []
    if src_url:
        external_references.append({"type": "distribution", "url": src_url})
    if src_repo:
        external_references.append({"type": "vcs", "url": src_repo})
    if external_references:
        linux_component["externalReferences"] = external_references

    # The downstream commit is the pedigree. CycloneDX models that as a commit
    # ancestry rather than a patch list, which is the honest shape here: there
    # are no out-of-tree diffs to enumerate, just the branch this was cut from.
    if src_commit:
        commit_entry = {"uid": src_commit}
        if src_repo:
            commit_entry["url"] = "%s/commit/%s" % (src_repo.rstrip("/"), src_commit)
        linux_component["pedigree"] = {"commits": [commit_entry]}

    components = [linux_component]
    depends_on = [kernel_ref]

    # GPU flavors bake in extra, separately-versioned artifacts.
    if flavor == "zone-amdgpu":
        fw_version = firmware_version_from_url(firmware_url)
        if fw_version:
            fw_ref = "pkg:generic/linux-firmware@%s" % fw_version
            fw_component = {
                "bom-ref": fw_ref,
                "type": "firmware",
                "name": "linux-firmware",
                "version": fw_version,
                "purl": fw_ref,
            }
            if firmware_url:
                fw_component["externalReferences"] = [
                    {"type": "distribution", "url": firmware_url}
                ]
            components.append(fw_component)
            depends_on.append(fw_ref)

    if flavor == "zone-nvidiagpu" and "+nvidia-" in version:
        nv_version = version.split("+nvidia-", 1)[1]
        nv_url = (
            "https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/%s.tar.gz"
            % nv_version
        )
        nv_ref = "pkg:github/NVIDIA/open-gpu-kernel-modules@%s" % nv_version
        components.append(
            {
                "bom-ref": nv_ref,
                "type": "library",
                "name": "nvidia-open-gpu-kernel-modules",
                "version": nv_version,
                "purl": nv_ref,
                "externalReferences": [{"type": "distribution", "url": nv_url}],
            }
        )
        depends_on.append(nv_ref)

    image_ref = "%s-kernel@%s" % (flavor, version)
    document = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "version": 1,
        "metadata": {
            "component": {
                "bom-ref": image_ref,
                "type": "container",
                "name": "%s-kernel" % flavor,
                "version": version,
            },
            "properties": [
                {"name": "dev.edera.kernel.flavor", "value": flavor},
                {"name": "dev.edera.kernel.source.repo", "value": src_repo},
                {"name": "dev.edera.kernel.source.ref", "value": src_ref},
                {"name": "dev.edera.kernel.source.commit", "value": src_commit},
            ],
        },
        "components": components,
        "dependencies": [{"ref": image_ref, "dependsOn": depends_on}],
    }

    with open("sbom.cdx.json", "w") as out:
        json.dump(document, out, indent=2)
        out.write("\n")

    # Human-readable summary for the build log.
    print(
        json.dumps(
            {
                "flavor": flavor,
                "version": version,
                "kernel": kernel_version,
                "source": "%s@%s" % (src_ref, src_commit),
                "components": len(components),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
