#!/usr/bin/env python3
"""Generate a curated CycloneDX SBOM for a published kernel manifest.

The kernel / kernel-SDK images are `FROM scratch` containing only compiled
artifacts, so scanning them yields nothing, and scanning the debian build
container yields hundreds of toolchain/base-OS packages that have no bearing on
the kernel that ships. Instead we describe what actually defines the kernel:

  - the upstream linux source version it was built from,
  - the patches applied to that source (the authoritative, arch-union list from
    patchlist.py), and
  - for GPU flavors, the firmware / nvidia module versions baked in.

All of this is architecture-independent -- the same source, patches, and module
versions apply to every arch in the manifest -- so a single SBOM correctly
describes the whole multi-arch image and stays correct as new arches (e.g.
arm64) are added. There are deliberately NO per-arch / package filter rules.

Reads from the environment (set by the merge job):
  KERNEL_VERSION   e.g. "6.18.35" or "6.18.35+nvidia-610.43.02"
  KERNEL_FLAVOR    e.g. "zone", "host", "zone-amdgpu", "zone-nvidiagpu"
  KERNEL_SRC_URL   upstream linux source tarball URL
  FIRMWARE_URL     linux-firmware tarball URL (only used for zone-amdgpu)

Writes sbom.cdx.json (CycloneDX 1.6) in the current directory.

This was created with Claude.
"""
import json
import os
import re
import subprocess
import sys


def applied_patches(version, flavor):
    """The patch files applied to this (version, flavor).

    Delegates to patchlist.py so the SBOM lists exactly the patches the build
    applies. patchlist.py matches constraints WITHOUT an arch argument, so this
    is the union across architectures -- correct for a manifest-level SBOM and
    forward-compatible with future arch-specific patches.
    """
    out = subprocess.run(
        [sys.executable, "hack/build/patchlist.py", version, flavor],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout
    return [line.strip() for line in out.splitlines() if line.strip()]


def firmware_version_from_url(url):
    # .../linux-firmware-<ver>.tar.xz
    match = re.search(r"linux-firmware-(.+?)\.tar\.", url or "")
    return match.group(1) if match else None


def main():
    version = os.environ["KERNEL_VERSION"]
    flavor = os.environ["KERNEL_FLAVOR"]
    src_url = os.environ.get("KERNEL_SRC_URL", "")
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
    if src_url:
        linux_component["externalReferences"] = [
            {"type": "distribution", "url": src_url}
        ]

    patches = applied_patches(version, flavor)
    if patches:
        linux_component["pedigree"] = {
            "patches": [
                {"type": "unofficial", "diff": {"url": patch}} for patch in patches
            ]
        }

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
                "patches": len(patches),
                "components": len(components),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
