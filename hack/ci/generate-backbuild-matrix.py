import json
import sys

from packaging.version import parse
from matrix import generate_matrix

data_path = sys.argv[1]
matrix_path = sys.argv[2]

release_info = json.loads(open("%s/releases.json" % data_path, "r").read())
all_releases = open("%s/all-versions" % data_path, "r").read().strip().splitlines()

tags = {}
major_minors = {}

for version in all_releases:
    parts = parse(version)

    # compilation issues with builds below this
    if parts.major < 5:
        continue

    if parts.major == 5:
        # allow 5.15+ or 5.10.200+
        if parts.minor < 15 or (parts.minor == 10 and parts.micro < 200):
            continue

    major_minor = "%s.%s" % (parts.major, parts.minor)

    if major_minor in tags:
        existing = tags[major_minor]
        if parse(existing) < parts:
            tags[major_minor] = version
            major_minors[major_minor] = version
    else:
        tags[major_minor] = version
        major_minors[major_minor] = version

for tag in list(tags.keys()):
    version = tags[tag]
    tags[version] = version

for release in release_info["releases"]:
    if not release["moniker"] in ["stable", "longterm"]:
        continue
    for key in list(tags.keys()):
        if tags[key] == release["version"]:
            tags.pop(key)
    for key in list(major_minors.keys()):
        if major_minors[key] == release["version"]:
            major_minors.pop(key)
    parts = parse(release["version"])
    major_minor = "%s.%s" % (parts.major, parts.minor)
    if major_minor in major_minors:
        major_minors.pop(major_minor)
    if major_minor in tags:
        tags.pop(major_minor)

generate_matrix(matrix_path, tags)
