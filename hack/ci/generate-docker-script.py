import os
import sys
import shlex


def read_metadata(path) -> dict[str, str]:
    metadata = {}
    lines = open(path, "r").read().strip().splitlines()
    for line in lines:
        parts = line.split("=", 1)
        metadata[parts[0]] = parts[1]
    return metadata


builds = {}

repository = sys.argv[2]
for kernel in os.listdir(sys.argv[1]):
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
    if not kernel_version in builds:
        builds[kernel_version] = {
            "version": kernel_version,
            "arch": [],
            "tags": kernel_tags,
        }
    builds[kernel_version]["arch"].append(
        {
            "arch": kernel_arch,
            "context": kernel_path,
            "config": kernel_config,
            "flavor": kernel_flavor,
        }
    )

print("#!/bin/sh")
print("set -e")
for build in list(builds.values()):
    for arch in build["arch"]:
        platform = ""
        if arch["arch"] == "aarch64":
            platform = "linux/aarch64"
        elif arch["arch"] == "x86_64":
            platform = "linux/amd64"
        if len(platform) == 0:
            print("unknown platform %s" % arch["arch"], file=sys.stderr)
            sys.exit(1)

        root = "%s:%s" % (repository, build["version"])
        command = [
            "docker",
            "build",
            "--tag",
            root,
            "--platform",
            platform,
            "-f",
            "hack/ci/kernel.dockerfile",
            "--annotation",
            "dev.edera.kernel.format.version=1",
            "--annotation",
            "dev.edera.kernel.version=%s" % build["version"],
            "--annotation",
            "dev.edera.kernel.flavor=%s" % arch["flavor"],
            "--annotation",
            "dev.edera.kernel.config=%s" % arch["config"],
            arch["context"],
        ]
        command = list(shlex.quote(item) for item in command)
        print(" ".join(command))
        for tag in build["tags"]:
            if tag == build["version"]:
                continue
            print("docker tag %s %s:%s" % (root, repository, tag))
