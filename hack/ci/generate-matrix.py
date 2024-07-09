import sys
import json
from packaging.version import Version, parse

flavors = ["standard", "dom0"]

data_path = sys.argv[1]
matrix_path = sys.argv[2]

release_info = json.loads(open("%s/releases.json" % data_path, "r").read())
latest_stable = release_info["latest_stable"]["version"]

known_releases = []

for release in release_info["releases"]:
    if release["moniker"] in ["stable", "longterm"]:
        known_releases.append(release["version"])

tags = {}
major_minors = {}

for version in known_releases:
    parts = parse(version)
    if parts.major < 5:
        continue

    if version == latest_stable:
        tags["stable"] = version
    major = str(parts.major)
    major_minor = "%s.%s" % (parts.major, parts.minor)

    if major in tags:
        existing = tags[major]
        if parse(existing) < parts:
            tags[major] = version
    else:
        tags[major] = version

    if major_minor in tags:
        existing = tags[major_minor]
        if parse(existing) < parts:
            tags[major_minor] = version
            major_minors[major_minor] = version
    else:
        tags[major_minor] = version
        major_minors[major_minor] = version

tags["latest"] = tags["stable"]

for tag in list(tags.keys()):
    version = tags[tag]
    tags[version] = version

unique_versions = list(set(tags.values()))
unique_versions.sort(key=Version)

version_builds = []

for version in unique_versions:
    version_tags = []
    for tag in tags:
        tag_version = tags[tag]
        if tag_version == version:
            version_tags.append(tag)
    parts = parse(version)
    src_url = "https://cdn.kernel.org/pub/linux/kernel/v%s.x/linux-%s.tar.xz" % (
        parts.major,
        version,
    )
    for flavor in flavors:
        version_builds.append(
            {
                "version": version,
                "tags": version_tags,
                "source": src_url,
                "flavor": flavor,
            }
        )

matrix = {
    "arch": ["x86_64", "aarch64"],
    "builds": version_builds,
}

matrix_file = open(matrix_path, "w")
matrix_file.write(json.dumps(matrix) + "\n")
