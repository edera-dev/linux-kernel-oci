from collections import OrderedDict
from packaging.version import parse
import json
import sys

all = OrderedDict()
for i, arg in enumerate(sys.argv):
    if i < 1:
        continue
    data = {"builds": []}
    with open(arg, "r") as f:
        data = json.load(f)
    for item in data["builds"]:
        key = "%s::%s" % (item["version"], item["flavor"])
        if key not in all:
            all[key] = item
        else:
            for tag in item["tags"]:
                if tag not in all[key]["tags"]:
                    all[key]["tags"].append(tag)
            for arch in item["architectures"]:
                if arch not in all[key]["architectures"]:
                    all[key]["architectures"].append(arch)

builds = list(all.values())
builds.sort(key=lambda build: parse(build["version"]))

print(
    json.dumps(
        {
            "builds": builds,
        },
    )
)
