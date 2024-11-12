import os
import sys
import shlex
from packaging.version import parse

DEFAULT_FLAVOR = "zone"

builds = {}

repository = sys.argv[1]

root_kernel_version = os.getenv("KERNEL_VERSION")
root_kernel_flavor = os.getenv("KERNEL_FLAVOR")
root_kernel_src_url = os.getenv("KERNEL_SRC_URL")
root_kernel_tags = os.getenv("KERNEL_TAGS", "").split(",")
root_kernel_architectures = os.getenv("KERNEL_ARCHITECTURES").split(",")
root_publish = os.getenv("KERNEL_PUBLISH") == "1"


kernel_version_info = parse(root_kernel_version)

platforms = []
for arch in root_kernel_architectures:
    platform = ""
    if arch == "aarch64":
        platform = "linux/aarch64"
    elif arch == "x86_64":
        platform = "linux/amd64"
    if len(platform) == 0:
        print("unknown platform %s" % arch, file=sys.stderr)
        sys.exit(1)
    platforms.append(platform)


def make_image_name(name, tag):
    result = repository
    result = result.replace("[image]", name)
    result = result.replace("[flavor]", root_kernel_flavor)
    result = result.replace("[major]", str(kernel_version_info.major))
    result = result.replace("[minor]", str(kernel_version_info.minor))
    result = result.replace("[patch]", str(kernel_version_info.micro))
    result = result.replace(
        "[series]", "%s.%s" % (kernel_version_info.major, kernel_version_info.minor)
    )
    result = result.replace("[tag]", tag)
    return result


def docker_build(
    target,
    name,
    tags=root_kernel_tags,
    version=root_kernel_version,
    format=None,
    publish=root_publish,
    pass_build_args=True,
):
    root = make_image_name(name, version)

    image_build_command = [
        "docker",
        "buildx",
        "build",
        "--builder",
        "edera",
        "--load",
        "-f",
        "Dockerfile",
        "--target",
        target,
        "--tag",
        root,
        "--iidfile",
        "image-id-%s-%s-%s" % (version, root_kernel_flavor, target),
    ]

    for platform in platforms:
        image_build_command += ["--platform", platform]

    if format is not None:
        image_build_command += [
            "--annotation",
            "dev.edera.kernel.version=%s" % version,
            "--annotation",
            "dev.edera.kernel.flavor=%s" % root_kernel_flavor,
        ]

    if pass_build_args:
        image_build_command += [
            "--build-arg",
            "KERNEL_VERSION=%s" % version,
            "--build-arg",
            "KERNEL_SRC_URL=%s" % root_kernel_src_url,
            "--build-arg",
            "KERNEL_FLAVOR=%s" % root_kernel_flavor,
        ]

    if format is not None:
        image_build_command += [
            "--annotation",
            "dev.edera.%s.format=1" % format,
        ]

    if publish:
        image_build_command += ["--push"]

    all_tags = [root]
    additional_tags = []

    for tag in tags:
        if tag == version:
            continue
        additional_tags.append(make_image_name(name, tag))

    all_tags += additional_tags
    for tag in additional_tags:
        image_build_command += [
            "--tag",
            tag,
        ]

    image_build_command += ["."]
    image_build_command = list(shlex.quote(item) for item in image_build_command)
    print(" ".join(image_build_command))

    if publish:
        for tag in all_tags:
            signing_command = [
                "cosign",
                "sign",
                "--yes",
                "%s@$(cat image-id-%s-%s-%s)"
                % (tag, root_kernel_version, root_kernel_flavor, target),
            ]
            print(" ".join(signing_command))


print("#!/bin/sh")
print("set -e")
print("docker buildx create --name edera --config hack/ci/buildkitd.toml")
print('trap "docker buildx rm edera" EXIT')
docker_build(
    target="kernelsrc",
    name="kernel-src",
    tags=["local"],
    publish=False,
    pass_build_args=False,
)
docker_build(
    target="buildenv",
    name="kernel-buildenv",
    version="local",
    tags=["local"],
    publish=False,
    pass_build_args=False,
)
docker_build("kernel", "[flavor]-kernel", root_kernel_tags, format="kernel")
docker_build("sdk", "[flavor]-kernel-sdk", root_kernel_tags, format="kernel.sdk")
