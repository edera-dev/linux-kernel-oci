import sys

from packaging.version import parse

from matrix import CONFIG
from util import matches_constraints

if len(sys.argv) != 3:
    print("Usage: patchlist <KERNEL_VERSION> <KERNEL_FLAVOR>")
    exit(1)

target_version = parse(sys.argv[1])
kernel_flavor = sys.argv[2]
series = "%s.%s" % (target_version.major, target_version.minor)


patches = CONFIG["patches"]

apply_patches = []


def maybe(m: dict[any, any], k: any) -> any:
    if k in m:
        return m[k]
    else:
        return None


for patch in patches:
    file_name = patch["patch"]
    order = maybe(patch, "order")

    if order is None:
        order = 1

    apply = matches_constraints(target_version, kernel_flavor, patch)

    if apply:
        apply_patches.append(
            {
                "patch": file_name,
                "order": order,
            }
        )

apply_patches.sort(key=lambda p: p["order"])

for patch in apply_patches:
    print("patches/%s" % patch["patch"])
