import os
import sys
import json
import stat
from typing import Optional

from packaging.version import parse, Version

from matrix import CONFIG
from util import format_image_name, maybe, smart_script_split, parse_text_bool

# Targets that are handled via docker run + host CCACHE packaging stages.
CCACHE_TARGET_MAP = {
    "kernel": "kernel-ccachebuild",
    "sdk": "sdk-ccachebuild",
}

# Targets skipped during the packaging phase (handled separately or not needed).
SKIP_PACKAGING_TARGETS = {"kernelsrc", "buildenv"}


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
        platform = arch_to_platform(arch)
        platforms.append(platform)
    return platforms


def arch_to_platform(arch: str) -> str:
    if arch == "aarch64":
        return "linux/aarch64"
    elif arch == "x86_64":
        return "linux/amd64"
    print("unknown arch %s" % arch, file=sys.stderr)
    sys.exit(1)


def docker_build_staged(
    version: str,
    flavor: str,
    architectures: list[str],
    src_url: str,
    firmware_url: str,
    firmware_sig_url: str,
) -> list[str]:
    """Build the build-staged image: buildenv with kernel source (and firmware/nvidia-modules for gpu flavors) baked in."""
    has_firmware = flavor == "zone-amdgpu"
    has_nvidia = flavor == "zone-nvidiagpu"
    if has_nvidia:
        nv_version = version.split("+nvidia-")[1] if "+nvidia-" in version else version.split("-nvidia-")[1]
        nv_modules_url = "https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/%s.tar.gz" % nv_version
    version = dockerify_version(version)
    if has_nvidia:
        target = "build-staged-nvidiagpu"
    elif has_firmware:
        target = "build-staged-amdgpu"
    else:
        target = "build-staged"
    iidfile = "image-id-%s-%s-%s" % (version, flavor, target)
    command = [
        "docker", "buildx", "build",
        "--builder", "edera",
        "--load",
        "-f", quoted("Dockerfile"),
        "--target", quoted(target),
        "--iidfile", quoted(iidfile),
    ]
    for platform in docker_platforms(architectures):
        command += ["--platform", quoted(platform)]
    command += ["--build-arg", quoted("KERNEL_SRC_URL=%s" % src_url)]
    if has_firmware:
        command += [
            "--build-arg", quoted("FIRMWARE_URL=%s" % firmware_url),
            "--build-arg", quoted("FIRMWARE_SIG_URL=%s" % firmware_sig_url),
        ]
    if has_nvidia:
        command += ["--build-arg", quoted("NV_MODULES_TARBALL_URL=%s" % nv_modules_url)]
    command += ["."]
    return [""] + smart_script_split(command, "stage=stage flavor=%s version=%s" % (flavor, version))


def docker_compile(
    version: str,
    flavor: str,
    architectures: list[str],
    firmware_url: str,
    firmware_sig_url: str,
) -> list[str]:
    """Generate docker run commands to compile the kernel with ccache."""
    lines = []
    has_firmware = flavor == "zone-amdgpu"
    has_nvidia = flavor == "zone-nvidiagpu"
    version = dockerify_version(version)
    if has_nvidia:
        stage_target = "build-staged-nvidiagpu"
    elif has_firmware:
        stage_target = "build-staged-amdgpu"
    else:
        stage_target = "build-staged"
    staged_iidfile = "image-id-%s-%s-%s" % (version, flavor, stage_target)

    lines += ["", "rm -rf target && mkdir -p target && chmod a+rwX target"]
    lines += ['mkdir -p "${HOME}/.cache/kernel-ccache" && chmod -R a+rwX "${HOME}/.cache/kernel-ccache"']

    for arch in architectures:
        platform = arch_to_platform(arch)
        compile_command = [
            "docker",
            "run",
            "--rm",
            "--platform", quoted(platform),
            "-e", quoted("KERNEL_VERSION=%s" % version),
            "-e", quoted("KERNEL_FLAVOR=%s" % flavor),
            "-e", quoted("KERNEL_SRC_URL=/build/override-kernel-src.tar.xz"),
            "-e", quoted("CCACHE_DIR=/home/build/.cache/ccache"),
            "-e", quoted("CCACHE_COMPRESS=1"),
            "-v", quoted("${HOME}/.cache/kernel-ccache:/home/build/.cache/ccache"),
            "-v", quoted("${PWD}/target:/build/target"),
        ]
        if has_firmware:
            compile_command += [
                "-e", quoted("FIRMWARE_URL=/build/override-firmware.tar.xz"),
                "-e", quoted("FIRMWARE_SIG_URL=/build/override-firmware.tar.sign"),
            ]
        if has_nvidia:
            compile_command += [
                "-e", quoted("NVIDIA_MODULES_PATH=/build/override-nvidia-modules.tar.gz"),
            ]
        compile_command += [
            '"$(cat %s)"' % staged_iidfile,
            "./hack/build/docker-build-internal.sh",
        ]
        lines += [""]
        lines += smart_script_split(
            compile_command,
            "stage=compile flavor=%s version=%s arch=%s" % (flavor, version, arch),
        )
    return lines



def docker_build(
    target: str,
    name: str,
    flavor: str,
    version: str,
    version_info: Version,
    tags: list[str],
    architectures: list[str],
    publish: bool,
    pass_build_args: bool,
    mark_format: Optional[str],
) -> list[str]:
    lines = []

    version = dockerify_version(version)
    actual_target = CCACHE_TARGET_MAP.get(target, target)

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
        quoted(actual_target),
        "--iidfile",
        quoted("image-id-%s-%s-%s" % (version, flavor, actual_target)),
    ]

    for build_platform in docker_platforms(architectures):
        image_build_command += ["--platform", quoted(build_platform)]

    if actual_target != target:
        image_build_command += ["--build-context", quoted("ccachebuild=target")]

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
            quoted("KERNEL_FLAVOR=%s" % flavor),
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
                    '%s@$(cat "image-id-%s-%s-%s")' % (tag, version, flavor, actual_target)
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

    # Phase 1: Build the build-staged image (buildenv + kernel source + firmware baked in).
    lines += docker_build_staged(
        version=kernel_version,
        flavor=kernel_flavor,
        architectures=kernel_architectures,
        src_url=kernel_src_url,
        firmware_url=firmware_url,
        firmware_sig_url=firmware_sig_url,
    )

    # Phase 2: Compile kernel via docker run with ccache bind-mounted from host.
    lines += docker_compile(
        version=kernel_version,
        flavor=kernel_flavor,
        architectures=kernel_architectures,
        firmware_url=firmware_url,
        firmware_sig_url=firmware_sig_url,
    )

    # Phase 3: Package kernel and SDK images from the ccache-built artifacts.
    for image_config in image_configs:
        target = image_config["target"]
        if target in SKIP_PACKAGING_TARGETS:
            continue
        image_name = image_config["name"]
        image_version = maybe(image_config, "version", kernel_version)
        image_tags = maybe(image_config, "tags", kernel_tags)
        image_format = maybe(image_config, "format")
        should_publish = maybe(image_config, "publish", is_publish_enabled())
        if not is_publish_enabled():
            should_publish = False
        should_pass_build_args = maybe(image_config, "passBuildArgs", True)
        lines += docker_build(
            target=target,
            name=image_name,
            version=image_version,
            version_info=kernel_version_info,
            tags=image_tags,
            publish=should_publish,
            pass_build_args=should_pass_build_args,
            mark_format=image_format,
            flavor=kernel_flavor,
            architectures=kernel_architectures,
        )
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
