import os
import sys
import shlex

DEFAULT_FLAVOR = "zone"


def read_metadata(path) -> dict[str, str]:
    metadata = {}
    lines = open(path, "r").read().strip().splitlines()
    for line in lines:
        parts = line.split("=", 1)
        metadata[parts[0]] = parts[1]
    return metadata


builds = {}

repository = sys.argv[2]
for kernel in sorted(os.listdir(sys.argv[1])):
    kernel_path = os.path.join(sys.argv[1], kernel)
    metadata_path = os.path.join(kernel_path, "metadata")
    if not os.path.isfile(metadata_path):
        continue
    metadata = read_metadata(metadata_path)
    kernel_arch = metadata["KERNEL_ARCH"]
    kernel_version = metadata["KERNEL_VERSION"]
    kernel_config = metadata["KERNEL_CONFIG"]
    kernel_flavor = metadata["KERNEL_FLAVOR"]
    kernel_tags = metadata["KERNEL_TAGS"].split(",")
    kernel_id = "%s-%s" % (kernel_version, kernel_flavor)
    if not kernel_id in builds:
        builds[kernel_id] = {
            "version": kernel_version,
            "arch": [],
            "tags": kernel_tags,
            "flavor": kernel_flavor,
        }
    builds[kernel_id]["arch"].append(
        {
            "arch": kernel_arch,
            "config": kernel_config,
        }
    )

print("#!/bin/sh")
print("set -e")
print("docker buildx create --name edera")
print('trap "docker buildx rm edera" EXIT')
for build in list(builds.values()):
    platforms = []
    for arch in build["arch"]:
        platform = ""
        if arch["arch"] == "aarch64":
            platform = "linux/aarch64"
        elif arch["arch"] == "x86_64":
            platform = "linux/amd64"
        if len(platform) == 0:
            print("unknown platform %s" % arch["arch"], file=sys.stderr)
            sys.exit(1)
        platforms.append(platform)

    root = "%s:%s" % (repository, build["version"])

    if build["flavor"] != DEFAULT_FLAVOR:
        root += "-%s" % build["flavor"]

    build_command = [
        "docker",
        "buildx",
        "build",
        "--builder",
        "edera",
        "--push",
    ]

    for platform in platforms:
        build_command += ["--platform", platform]

    tags = [root]
    for tag in build["tags"]:
        if tag == build["version"]:
            continue
        item = "%s:%s" % (repository, tag)
        if build["flavor"] != DEFAULT_FLAVOR:
            item += "-%s" % build["flavor"]
        tags.append(item)

    tags.sort()
    for tag in tags:
        build_command += ["--tag", tag]

    build_command += [
        "-f",
        "hack/ci/kernel.dockerfile",
        "--build-arg",
        "KERNEL_VERSION=%s" % build["version"],
        "--build-arg",
        "KERNEL_FLAVOR=%s" % build["flavor"],
        "--annotation",
        "dev.edera.kernel.format=1",
        "--annotation",
        "dev.edera.kernel.version=%s" % build["version"],
        "--annotation",
        "dev.edera.kernel.flavor=%s" % build["flavor"],
        "--iidfile",
        "kernel-image-id-%s-%s" % (build["version"], build["flavor"]),
        sys.argv[1],
    ]
    build_command = list(shlex.quote(item) for item in build_command)
    print(" ".join(build_command))

    base_signing_command = [
        "cosign",
        "sign",
        "--yes",
    ]

    for tag in tags:
        signing_command = base_signing_command + [
            "%s@$(cat kernel-image-id-%s-%s)"
            % (tag, build["version"], build["flavor"]),
        ]
        print(" ".join(signing_command))
