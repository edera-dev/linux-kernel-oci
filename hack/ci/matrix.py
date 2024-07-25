import json

from packaging.version import Version, parse

BUILD_FLAVORS = ["standard", "dom0"]
BUILD_ARCHITECTURES = ["x86_64", "aarch64"]


def generate_matrix(matrix_path, tags):
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
        for flavor in BUILD_FLAVORS:
            version_builds.append(
                {
                    "version": version,
                    "tags": version_tags,
                    "source": src_url,
                    "flavor": flavor,
                }
            )

    matrix = {
        "arch": BUILD_ARCHITECTURES,
        "builds": version_builds,
    }

    matrix_file = open(matrix_path, "w")
    matrix_file.write(json.dumps(matrix) + "\n")
