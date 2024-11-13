import os
import sys
import shlex
import json
import stat
from typing import Optional

from packaging.version import parse, Version

from util import format_image_name, maybe, smart_script_split

with open("config.json", "r") as f:
    CONFIG = json.load(f)


def is_publish_enabled():
    root_publish = os.getenv("KERNEL_PUBLISH") == "1"
    return root_publish


def docker_platforms(architectures: list[str]) -> list[str]:
    platforms = []
    for arch in architectures:
        platform = ""
        if arch == "aarch64":
            platform = "linux/aarch64"
        elif arch == "x86_64":
            platform = "linux/amd64"
        if len(platform) == 0:
            print("unknown platform %s" % arch, file=sys.stderr)
            sys.exit(1)
        platforms.append(platform)
    return platforms


def docker_build(
    target: str,
    name: str,
    flavor: str,
    version: str,
    version_info: Version,
    tags: list[str],
    architectures: list[str],
    src_url: str,
    publish: bool,
    pass_build_args: bool,
    mark_format: Optional[str],
) -> list[str]:
    lines = []

    root = format_image_name(
        image_name_format=CONFIG["imageNameFormat"],
        flavor=flavor,
        version_info=version_info,
        name=name,
        tag=version,
    )

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
        "--iidfile",
        "image-id-%s-%s-%s" % (version, flavor, target),
    ]

    for build_platform in docker_platforms(architectures):
        image_build_command += ["--platform", build_platform]

    if mark_format is not None:
        image_build_command += [
            "--annotation",
            "dev.edera.kernel.version=%s" % version,
            "--annotation",
            "dev.edera.kernel.flavor=%s" % flavor,
        ]

    if pass_build_args:
        image_build_command += [
            "--build-arg",
            "KERNEL_VERSION=%s" % version,
            "--build-arg",
            "KERNEL_SRC_URL=%s" % src_url,
            "--build-arg",
            "KERNEL_FLAVOR=%s" % flavor,
        ]

    if mark_format is not None:
        image_build_command += [
            "--annotation",
            "dev.edera.%s.format=1" % mark_format,
        ]

    if publish:
        image_build_command += ["--push"]

    all_tags = [root]
    additional_tags = []

    for tag in tags:
        if tag == version:
            continue
        additional_tags.append(
            format_image_name(
                image_name_format=CONFIG["imageNameFormat"],
                flavor=flavor,
                version_info=version_info,
                name=name,
                tag=tag,
            )
        )

    all_tags += additional_tags
    all_tags.sort()
    for tag in all_tags:
        image_build_command += [
            "--tag",
            tag,
        ]

    image_build_command += ["."]
    image_build_command = list(shlex.quote(item) for item in image_build_command)
    lines += smart_script_split(image_build_command, "build %s" % root)

    if publish:
        for tag in all_tags:
            image_signing_command = [
                "cosign",
                "sign",
                "--yes",
                "%s@$(cat image-id-%s-%s-%s)" % (tag, version, flavor, target),
            ]
            lines += smart_script_split(image_signing_command, "sign %s" % tag)
    return lines


def generate_header() -> list[str]:
    return [
        "#/bin/sh",
        "set -e",
        "docker buildx create --name edera --config hack/build/buildkitd.toml",
        'trap "docker buildx rm edera" EXIT',
    ]


def generate_builds(
    kernel_version: str,
    kernel_flavor: str,
    kernel_src_url: str,
    kernel_tags: list[str],
    kernel_architectures: list[str],
):
    lines = []
    kernel_version_info = parse(kernel_version)
    image_configs = CONFIG["images"]
    for image_config in image_configs:
        image_name = image_config["name"]
        image_target = image_config["target"]
        image_version = maybe(image_config, "version", kernel_version)
        image_tags = maybe(image_config, "tags", kernel_tags)
        image_format = maybe(image_config, "format")
        should_publish = maybe(image_config, "publish", is_publish_enabled())
        if not is_publish_enabled():
            should_publish = False
        should_pass_build_args = maybe(image_config, "passBuildArgs", True)
        image_lines = docker_build(
            target=image_target,
            name=image_name,
            version=image_version,
            version_info=kernel_version_info,
            tags=image_tags,
            publish=should_publish,
            pass_build_args=should_pass_build_args,
            mark_format=image_format,
            flavor=kernel_flavor,
            src_url=kernel_src_url,
            architectures=kernel_architectures,
        )
        lines += image_lines
    return lines


def generate_build_from_env() -> list[str]:
    root_kernel_version = os.getenv("KERNEL_VERSION")
    root_kernel_flavor = os.getenv("KERNEL_FLAVOR")
    root_kernel_src_url = os.getenv("KERNEL_SRC_URL")
    root_kernel_tags = os.getenv("KERNEL_TAGS", "").split(",")
    root_kernel_architectures = os.getenv("KERNEL_ARCHITECTURES").split(",")
    return generate_builds(
        kernel_version=root_kernel_version,
        kernel_flavor=root_kernel_flavor,
        kernel_src_url=root_kernel_src_url,
        kernel_tags=root_kernel_tags,
        kernel_architectures=root_kernel_architectures,
    )


def generate_builds_from_matrix(matrix) -> list[str]:
    lines = []
    for build in matrix["builds"]:
        build_version = build["version"]
        build_flavor = build["flavor"]
        build_source = build["source"]
        build_tags = build["tags"]
        build_architectures = build["architectures"]
        lines += generate_builds(
            kernel_version=build_version,
            kernel_flavor=build_flavor,
            kernel_src_url=build_source,
            kernel_tags=build_tags,
            kernel_architectures=build_architectures,
        )
    return lines


def main():
    script_lines = []

    script_lines += generate_header()

    if len(sys.argv) > 1:
        matrix_path = sys.argv[1]
        with open(matrix_path, "r") as mf:
            loaded_matrix = json.load(mf)
        script_lines += generate_builds_from_matrix(loaded_matrix)

    else:
        script_lines += generate_build_from_env()
    with open("docker.sh", "w") as df:
        script_lines.append("")
        df.write("\n".join(script_lines))
    stats = os.stat("docker.sh")
    os.chmod("docker.sh", stats.st_mode | stat.S_IEXEC)


if __name__ == "__main__":
    main()
