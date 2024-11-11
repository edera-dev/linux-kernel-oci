import json
import os
import sys
from packaging.version import parse
from pathlib import Path

if len(sys.argv) != 3:
    print("Usage: patchlist <KERNEL_VERSION> <KERNEL_FLAVOR>")
    exit(1)

target_version = parse(sys.argv[1])
kernel_flavor = sys.argv[2]
series = "%s.%s" % (target_version.major, target_version.minor)

common_patches = []
with open("patches/patches.json") as f:
    common_patches = json.load(f)

apply_patches = []


def maybe(m, k):
    if k in m:
        return m[k]
    else:
        return None


for patch in common_patches:
    file_name = patch["patch"]
    order = maybe(patch, "order")
    flavors = maybe(patch, "flavors")
    lower = maybe(patch, "lower")
    only_series = maybe(patch, "series")
    upper = maybe(patch, "upper")

    if order is None:
        order = 1

    if lower is not None:
        lower = parse(lower)
    if upper is not None:
        upper = parse(upper)

    apply = True

    if lower is None and upper is not None:
        if target_version > upper:
            apply = False

    if lower is not None and upper is None:
        if target_version < lower:
            apply = False

    if lower is not None and upper is not None:
        if target_version < lower or target_version > upper:
            apply = False

    if only_series is not None and series not in only_series:
        apply = False

    if flavors is not None and kernel_flavor not in flavors:
        apply = False

    if apply:
        apply_patches.append(
            {
                "patch": file_name,
                "order": order,
            }
        )

apply_patches.sort(key=lambda patch: patch["order"])

for patch in apply_patches:
    print("patches/%s" % patch["patch"])
