import sys
import json
from packaging.version import parse

matrix_path = sys.argv[1]

builds = []
with open(matrix_path, "r") as f:
    matrix = json.load(f)
    builds = matrix["builds"]

builds.sort(key=lambda build: parse(build["version"]))

if len(builds) > 250:
    builds = builds[-250:]

print(
    json.dumps(
        {
            "builds": builds,
        },
    )
)
