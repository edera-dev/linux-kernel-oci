import os
import sys
import shlex

DEFAULT_FLAVOR = "zone"

builds = {}

repository = sys.argv[1]

kernel_version = os.getenv("KERNEL_VERSION")
kernel_flavor = os.getenv("KERNEL_FLAVOR")
kernel_src_url = os.getenv("KERNEL_SRC_URL")
kernel_tags = os.getenv("KERNEL_TAGS", "").split(",")
kernel_architectures = os.getenv("KERNEL_ARCHITECTURES").split(",")


def docker_build_and_sign(target, tags, suffix="", format_type=None):
    platforms = []
    for arch in kernel_architectures:
        platform = ""
        if arch == "aarch64":
            platform = "linux/aarch64"
        elif arch == "x86_64":
            platform = "linux/amd64"
        if len(platform) == 0:
            print("unknown platform %s" % arch, file=sys.stderr)
            sys.exit(1)
        platforms.append(platform)

    image_build_command = [
        "docker",
        "buildx",
        "build",
        "--builder",
        "edera",
        "-f",
        "Dockerfile",
        "--build-arg",
        "KERNEL_VERSION=%s" % kernel_version,
        "--build-arg",
        "KERNEL_SRC_URL=%s" % kernel_src_url,
        "--build-arg",
        "KERNEL_FLAVOR=%s" % kernel_flavor,
        "--annotation",
        "dev.edera.kernel.version=%s" % kernel_version,
        "--annotation",
        "dev.edera.kernel.flavor=%s" % kernel_flavor,
        "--iidfile",
        "image-id-%s-%s-%s" % (kernel_version, kernel_flavor, target),
        "--load",
    ]

    if format_type is not None:
        image_build_command += [
            "--annotation",
            "dev.edera.%s.format=1" % format_type,
        ]

    publish = os.getenv("KERNEL_PUBLISH") == "1"
    if publish:
        image_build_command += ["--push"]

    for platform in platforms:
        image_build_command += ["--platform", platform]

    root = "%s%s:%s" % (repository, suffix, kernel_version)
    tags = [root]

    for tag in kernel_tags:
        if tag == kernel_version:
            continue
        tag = "%s%s:%s" % (repository, suffix, tag)
        if kernel_flavor != DEFAULT_FLAVOR:
            tag += "-%s" % kernel_flavor
        tags.append(tag)

    for tag in tags:
        image_build_command += [
            "--tag",
            tag,
        ]

    image_build_command += ["."]
    image_build_command = list(shlex.quote(item) for item in image_build_command)
    print(" ".join(image_build_command))

    if publish:
        for tag in tags:
            signing_command = [
                "cosign",
                "sign",
                "--yes",
                "%s@$(cat image-id-%s-%s-%s)"
                % (tag, kernel_version, kernel_flavor, target),
            ]
            print(" ".join(signing_command))


print("#!/bin/sh")
print("set -e")
print("docker buildx create --name edera")
print('trap "docker buildx rm edera" EXIT')
docker_build_and_sign("kernel", kernel_tags, format_type="kernel")
docker_build_and_sign("sdk", kernel_tags, format_type="kernel.sdk")
