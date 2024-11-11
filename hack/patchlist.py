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
with open("patches/common/patches.json") as f:
    common_patches = json.load(f)

apply_patches = []

def maybe(m, k):
    if k in m:
        return m[k]
    else:
        return None

for patch in common_patches:
    file_name = patch["patch"]
    order = patch["order"]
    lower = maybe(patch, "lower")
    only_series = maybe(patch, "series")
    upper = maybe(patch, "upper")
    if lower is not None:
        lower = parse(lower)
    if upper is not None:
        upper = parse(upper)

    apply = False

    if lower is None and upper is not None:
        if target_version <= upper:
            apply = True

    if lower is not None and upper is None:
        if target_version >= lower:
            apply = True

    if lower is not None and upper is not None:
        if target_version >= lower and target_version <= upper:
            apply = True

    if only_series is not None and only_series != series:
        apply = False

    if apply:
        apply_patches.append({
            "patch": "patches/common/%s" % file_name,
            "order": order,
        })

base_series_path = Path("patches/%s/base/series" % series)
if base_series_path.is_file():
    with base_series_path.open() as base_series_file:
        lines = base_series_file.readlines()
        for i, line in enumerate(lines):
            line = line.strip()
            if len(line) == 0:
                continue
            apply_patches.append({
                "patch": "patches/%s/base/%s" % (series, line),
                "order": i + 1,
            })

flavor_series_path = Path("patches/%s/%s/series" % (series, kernel_flavor))
if flavor_series_path.is_file():
    with flavor_series_path.open() as flavor_series_file:
        lines = flavor_series_file.readlines()
        for i, line in enumerate(lines):
            line = line.strip()
            if len(line) == 0:
                continue
            apply_patches.append({
                "patch": "patches/%s/%s/%s" % (series, kernel_flavor, line),
                "order": i + 1,
            })

apply_patches.sort(key=lambda patch: patch["order"])

for patch in apply_patches:
    print(patch["patch"])
