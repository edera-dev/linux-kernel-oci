import sys
import json
from packaging.version import parse
from util import format_image_name

matrix_path = sys.argv[1]
repository = sys.argv[2]

builds = []
with open(matrix_path, "r") as f:
    matrix = json.load(f)
    builds = matrix["builds"]

for build in builds:
    version = build["version"]
    version_info = parse(version)
    flavor = build["flavor"]
    tags = list(build["tags"])
    if version not in tags:
        tags.append(version)
    produces = []
    for tag in tags:
        kernel_output = format_image_name(
            repository, flavor, version_info, "[flavor]-kernel", tag
        )
        kernel_sdk_output = format_image_name(
            repository, flavor, version_info, "[flavor]-kernel-sdk", tag
        )
        produces.append(kernel_output)
        produces.append(kernel_sdk_output)
    build["produces"] = produces

produce_check = {}

for build in builds:
    for produce in build["produces"]:
        if produce in produce_check:
            raise Exception("ERROR: %s was produced more than once" % produce)
        else:
            produce_check[produce] = produce

print(
    json.dumps(
        {
            "builds": builds,
        },
    )
)
