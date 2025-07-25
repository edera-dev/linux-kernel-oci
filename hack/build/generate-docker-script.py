import os
import sys
import json
import stat
from typing import Optional

from packaging.version import parse, Version

from matrix import CONFIG
from util import format_image_name, maybe, smart_script_split, parse_text_bool


def is_publish_enabled() -> bool:
    root_publish = os.getenv("KERNEL_PUBLISH", "false")
    return parse_text_bool(root_publish)


def quoted(text: str) -> str:
    return '"%s"' % text

def dockerify_version(version_string: str) -> str:
    # "+" is valid for both python versions and semver,
    # but docker rejects it for tags, so sanitize
    return version_string.replace('+', '-')


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
    firmware_url: str,
    firmware_sig_url: str,
) -> list[str]:
    lines = []

    version = dockerify_version(version)
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
        quoted("Dockerfile"),
        "--target",
        quoted(target),
        "--iidfile",
        quoted("image-id-%s-%s-%s" % (version, flavor, target)),
    ]

    for build_platform in docker_platforms(architectures):
        image_build_command += ["--platform", quoted(build_platform)]

    if mark_format is not None:
        image_build_command += [
            "--annotation",
            quoted("dev.edera.kernel.version=%s" % version),
            "--annotation",
            quoted("dev.edera.kernel.flavor=%s" % flavor),
        ]

    if pass_build_args:
        image_build_command += [
            "--build-arg",
            quoted("KERNEL_VERSION=%s" % version),
            "--build-arg",
            quoted("KERNEL_SRC_URL=%s" % src_url),
            "--build-arg",
            quoted("KERNEL_FLAVOR=%s" % flavor),
            "--build-arg",
            quoted("FIRMWARE_URL=%s" % firmware_url),
            "--build-arg",
            quoted("FIRMWARE_SIG_URL=%s" % firmware_sig_url),
        ]

    if mark_format is not None:
        image_build_command += [
            "--annotation",
            quoted("dev.edera.%s.format=1" % mark_format),
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
            quoted(tag),
        ]

    image_build_command += ["."]
    lines += [""]
    lines += smart_script_split(image_build_command, "stage=build image=%s" % root)

    if publish:
        for tag in all_tags:
            image_signing_command = [
                "cosign",
                "sign",
                "--yes",
                quoted(
                    '%s@$(cat "image-id-%s-%s-%s")' % (tag, version, flavor, target)
                ),
            ]
            lines += [""]
            lines += smart_script_split(
                image_signing_command, "stage=sign image=%s" % tag
            )
    return lines


def generate_header() -> list[str]:
    return [
        "#!/bin/sh",
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
    firmware_url: str,
    firmware_sig_url: str,
) -> list[str]:
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
            firmware_url=firmware_url,
            firmware_sig_url=firmware_sig_url,
        )
        lines += image_lines
    return lines


def generate_build_from_env() -> list[str]:
    root_kernel_version = os.getenv("KERNEL_VERSION")
    root_kernel_flavor = os.getenv("KERNEL_FLAVOR")
    root_kernel_src_url = os.getenv("KERNEL_SRC_URL")
    root_firmware_url = os.getenv("FIRMWARE_URL")
    root_firmware_sig_url = os.getenv("FIRMWARE_SIG_URL")
    root_kernel_tags = os.getenv("KERNEL_TAGS", "").split(",")
    root_kernel_architectures = os.getenv("KERNEL_ARCHITECTURES").split(",")
    return generate_builds(
        kernel_version=root_kernel_version,
        kernel_flavor=root_kernel_flavor,
        kernel_src_url=root_kernel_src_url,
        kernel_tags=root_kernel_tags,
        kernel_architectures=root_kernel_architectures,
        firmware_url=root_firmware_url,
        firmware_sig_url=root_firmware_sig_url,
    )


def generate_builds_from_matrix(matrix) -> list[str]:
    lines = []
    builds = matrix["builds"]  # type: list[dict[str, any]]
    for build in builds:
        build_version = build["version"]
        build_flavor = build["flavor"]
        build_source = build["source"]
        firmware_url = build["firmware_url"]
        firmware_sig_url = build["firmware_sig_url"]
        build_tags = build["tags"]
        build_architectures = build["architectures"]
        lines += generate_builds(
            kernel_version=build_version,
            kernel_flavor=build_flavor,
            kernel_src_url=build_source,
            kernel_tags=build_tags,
            kernel_architectures=build_architectures,
            firmware_url=firmware_url,
            firmware_sig_url=firmware_sig_url,
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
