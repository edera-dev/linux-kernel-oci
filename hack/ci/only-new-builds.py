import sys
import json
import subprocess
import copy
from packaging.version import parse

matrix_path = sys.argv[1]

builds = []
with open(matrix_path, "r") as f:
    matrix = json.load(f)
    builds = matrix["builds"]

images = []
for build in builds:
    if "produces" not in build:
        raise Exception("build did not contain a produces key")
    for produce in build["produces"]:
        parts = produce.split(":")
        image = parts[0]
        if image not in images:
            images.append(image)

existing = {}

for image in images:
    # ignore return code, we just want stdout
    result = subprocess.run(
        ["crane", "ls", image], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
    )
    tags = result.stdout.splitlines(keepends=False)
    existing[image] = tags

should_builds = []
for build in builds:
    should_build = False
    for produce in build["produces"]:
        parts = produce.split(":")
        image = parts[0]
        tag = parts[1]
        if image not in existing:
            should_build = True
        elif tag not in existing[image]:
            should_build = True
    if should_build:
        build = copy.copy(build)
        del build["produces"]
        should_builds.append(build)

print(
    json.dumps(
        {
            "builds": should_builds,
        },
    )
)
