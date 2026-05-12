import json
import os
import stat
import sys
from typing import Any, Optional

from matrix import CONFIG
from packaging.version import Version, parse
from util import (
    format_image_name,
    get_branch_tag_suffix,
    maybe,
    parse_text_bool,
    smart_script_split,
)

# Targets that are handled via docker run + host CCACHE packaging stages.
CCACHE_TARGET_MAP = {
    "kernel": "kernel-ccachebuild",
    "sdk": "sdk-ccachebuild",
}

# Targets skipped during the packaging phase (handled separately or not needed).
SKIP_PACKAGING_TARGETS = {"kernelsrc", "buildenv"}

# Per-arch digests file consumed by the merge job to assemble manifest lists.
DIGESTS_FILE = "digests.json"


def is_publish_enabled() -> bool:
    root_publish = os.getenv("KERNEL_PUBLISH", "false")
    return parse_text_bool(root_publish)


def quoted(text: str) -> str:
    return '"%s"' % text


def dockerify_version(version_string: str) -> str:
    # "+" is valid for both python versions and semver,
    # but docker rejects it for tags, so sanitize
    return version_string.replace("+", "-")


def arch_to_platform(arch: str) -> str:
    if arch == "aarch64":
        return "linux/aarch64"
    elif arch == "x86_64":
        return "linux/amd64"
    print("unknown arch %s" % arch, file=sys.stderr)
    sys.exit(1)


def docker_platforms(architectures: list[str]) -> list[str]:
    return [arch_to_platform(a) for a in architectures]


def metadata_path(image_root: str, target: str) -> str:
    # buildx metadata file paths must be unique per build invocation;
    # use a sanitized image-name + target as the key.
    safe = image_root.replace("/", "_").replace(":", "_")
    return "metadata-%s-%s.json" % (safe, target)


def docker_build_staged(
    version: str,
    flavor: str,
    archs: list[str],
    src_url: str,
    firmware_url: str,
    firmware_sig_url: str,
) -> list[str]:
    """Build the build-staged image: buildenv with kernel source (and firmware/nvidia-modules for gpu flavors) baked in."""
    has_firmware = flavor == "zone-amdgpu"
    has_nvidia = flavor == "zone-nvidiagpu"
    if has_nvidia:
        nv_version = (
            version.split("+nvidia-")[1]
            if "+nvidia-" in version
            else version.split("-nvidia-")[1]
        )
        nv_modules_url = (
            "https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/%s.tar.gz"
            % nv_version
        )
    version = dockerify_version(version)
    if has_nvidia:
        target = "build-staged-nvidiagpu"
    elif has_firmware:
        target = "build-staged-amdgpu"
    else:
        target = "build-staged"
    iidfile = "image-id-%s-%s-%s" % (version, flavor, target)
    command = [
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
        quoted(iidfile),
    ]
    for platform in docker_platforms(archs):
        command += ["--platform", quoted(platform)]
    command += ["--build-arg", quoted("KERNEL_SRC_URL=%s" % src_url)]
    if has_firmware:
        command += [
            "--build-arg",
            quoted("FIRMWARE_URL=%s" % firmware_url),
            "--build-arg",
            quoted("FIRMWARE_SIG_URL=%s" % firmware_sig_url),
        ]
    if has_nvidia:
        command += ["--build-arg", quoted("NV_MODULES_TARBALL_URL=%s" % nv_modules_url)]
    command += ["."]
    return [""] + smart_script_split(
        command,
        "stage=stage flavor=%s version=%s arch=%s" % (flavor, version, ",".join(archs)),
    )


def docker_compile(
    version: str,
    flavor: str,
    archs: list[str],
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
    lines += [
        'mkdir -p "${HOME}/.cache/kernel-ccache" && chmod -R a+rwX "${HOME}/.cache/kernel-ccache"'
    ]

    for arch in archs:
        platform = arch_to_platform(arch)
        compile_command = [
            "docker",
            "run",
            "--rm",
            "--platform",
            quoted(platform),
            "-e",
            quoted("KERNEL_VERSION=%s" % version),
            "-e",
            quoted("KERNEL_FLAVOR=%s" % flavor),
            "-e",
            quoted("KERNEL_SRC_URL=/build/override-kernel-src.tar.xz"),
            "-e",
            quoted("CCACHE_DIR=/home/build/.cache/ccache"),
            "-e",
            quoted("CCACHE_COMPRESS=1"),
            "-v",
            quoted("${HOME}/.cache/kernel-ccache:/home/build/.cache/ccache"),
            "-v",
            quoted("${PWD}/target:/build/target"),
        ]
        if has_firmware:
            compile_command += [
                "-e",
                quoted("FIRMWARE_URL=/build/override-firmware.tar.xz"),
                "-e",
                quoted("FIRMWARE_SIG_URL=/build/override-firmware.tar.sign"),
            ]
        if has_nvidia:
            compile_command += [
                "-e",
                quoted("NVIDIA_MODULES_PATH=/build/override-nvidia-modules.tar.gz"),
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
    archs: list[str],
    publish: bool,
    pass_build_args: bool,
    mark_format: Optional[str],
    firmware_url: str,
    firmware_sig_url: str,
    tag_suffix: Optional[str] = None,
) -> list[str]:
    lines = []

    version = dockerify_version(version)
    actual_target = CCACHE_TARGET_MAP.get(target, target)

    # tag_version is the version string used for OCI tags; version is the
    # actual kernel version passed as a build arg and recorded in annotations.
    # They differ when building from a non-main branch to avoid tag collisions.
    # Tags in the list are already branch-suffixed (applied during matrix generation).
    tag_version = "%s-%s" % (version, tag_suffix) if tag_suffix else version

    image_full = format_image_name(
        image_name_format=CONFIG["imageNameFormat"],
        flavor=flavor,
        version_info=version_info,
        name=name,
        tag=tag_version,
    )
    image_root = image_full.split(":")[0]

    # CI path: single-arch matrix entry + publish → push by digest only, let the
    # merge job tag and assemble the manifest list once every arch is done.
    # Everything else (multi-arch local, single-arch local) uses the original
    # single-invocation buildx flow with --load or --push --tag.
    use_push_by_digest = publish and len(archs) == 1

    image_build_command = [
        "docker",
        "buildx",
        "build",
        "--builder",
        "edera",
        "-f",
        quoted("Dockerfile"),
        "--target",
        quoted(actual_target),
    ]
    for platform in docker_platforms(archs):
        image_build_command += ["--platform", quoted(platform)]

    if actual_target != target:
        image_build_command += ["--build-context", quoted("ccachebuild=target")]

    if mark_format is not None:
        image_build_command += [
            "--annotation",
            quoted("dev.edera.kernel.version=%s" % version),
            "--annotation",
            quoted("dev.edera.kernel.flavor=%s" % flavor),
            "--annotation",
            quoted("dev.edera.%s.format=1" % mark_format),
        ]

    if pass_build_args:
        image_build_command += [
            "--build-arg",
            quoted("KERNEL_VERSION=%s" % version),
            "--build-arg",
            quoted("KERNEL_FLAVOR=%s" % flavor),
        ]

    if use_push_by_digest:
        metadata_file = metadata_path(image_root, actual_target)
        image_build_command += [
            "--metadata-file",
            quoted(metadata_file),
            "--output",
            quoted(
                "type=image,name=%s,push-by-digest=true,name-canonical=true,push=true"
                % image_root
            ),
            ".",
        ]
        lines += [""]
        lines += smart_script_split(
            image_build_command, "stage=build image=%s arch=%s" % (image_root, archs[0])
        )
        record_command = [
            "python3",
            "hack/build/record-digest.py",
            quoted(image_root),
            quoted(metadata_file),
            quoted(DIGESTS_FILE),
        ]
        lines += [""]
        lines += smart_script_split(
            record_command,
            "stage=record-digest image=%s arch=%s" % (image_root, archs[0]),
        )
        return lines

    # Tagged path: either local --load (no publish) or multi-arch --push (local
    # multi-arch publish, e.g. someone running the env-driven script with
    # KERNEL_ARCHITECTURES=x86_64,aarch64 and KERNEL_PUBLISH=true). Both produce
    # a tagged image (or multi-arch manifest list) in one buildx invocation.
    all_tags = sorted({tag_version, *tags})
    for tag in all_tags:
        tagged = format_image_name(
            image_name_format=CONFIG["imageNameFormat"],
            flavor=flavor,
            version_info=version_info,
            name=name,
            tag=tag,
        )
        image_build_command += ["--tag", quoted(tagged)]

    iidfile = "image-id-%s-%s-%s" % (tag_version, flavor, actual_target)
    image_build_command += ["--iidfile", quoted(iidfile)]
    if publish:
        image_build_command += ["--push"]
    else:
        image_build_command += ["--load"]
    image_build_command += ["."]
    lines += [""]
    lines += smart_script_split(
        image_build_command,
        "stage=build image=%s arch=%s" % (image_root, ",".join(archs)),
    )

    if publish:
        for tag in all_tags:
            tagged = format_image_name(
                image_name_format=CONFIG["imageNameFormat"],
                flavor=flavor,
                version_info=version_info,
                name=name,
                tag=tag,
            )
            image_signing_command = [
                "cosign",
                "sign",
                "--yes",
                quoted('%s@$(cat "%s")' % (tagged, iidfile)),
            ]
            lines += [""]
            lines += smart_script_split(
                image_signing_command, "stage=sign image=%s" % tagged
            )
    return lines


def generate_header() -> list[str]:
    lines = [
        "#!/bin/sh",
        "set -e",
        "docker buildx create --name edera --config hack/build/buildkitd.toml",
        'trap "docker buildx rm edera" EXIT',
    ]
    if is_publish_enabled():
        # Start fresh so a re-run within the same workspace doesn't pick up
        # digests from a previous (failed) invocation.
        lines += ['rm -f "%s"' % DIGESTS_FILE]
    return lines


def generate_builds(
    kernel_version: str,
    kernel_flavor: str,
    kernel_src_url: str,
    kernel_tags: list[str],
    kernel_archs: list[str],
    firmware_url: str,
    firmware_sig_url: str,
    tag_suffix: Optional[str] = None,
) -> list[str]:
    lines = []
    kernel_version_info = parse(kernel_version)
    image_configs = CONFIG["images"]

    # Phase 1: Build the build-staged image (buildenv + kernel source + firmware baked in).
    lines += docker_build_staged(
        version=kernel_version,
        flavor=kernel_flavor,
        archs=kernel_archs,
        src_url=kernel_src_url,
        firmware_url=firmware_url,
        firmware_sig_url=firmware_sig_url,
    )

    # Phase 2: Compile kernel via docker run with ccache bind-mounted from host.
    lines += docker_compile(
        version=kernel_version,
        flavor=kernel_flavor,
        archs=kernel_archs,
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
            archs=kernel_archs,
            firmware_url=firmware_url,
            firmware_sig_url=firmware_sig_url,
            tag_suffix=tag_suffix,
        )
    return lines


def generate_build_from_env() -> list[str]:
    """Env-driven (non-matrix) build, e.g. invoked directly from a developer's
    shell. Multi-arch is preserved here: pass KERNEL_ARCHITECTURES=x86_64,aarch64
    to build a multi-platform image with one buildx invocation (relies on QEMU
    + containerd-snapshotter locally). KERNEL_ARCH is also accepted as a
    convenience alias for a single arch."""
    root_kernel_version = os.environ["KERNEL_VERSION"]
    root_kernel_flavor = os.environ["KERNEL_FLAVOR"]
    root_kernel_src_url = os.environ["KERNEL_SRC_URL"]
    root_firmware_url = os.environ["FIRMWARE_URL"]
    root_firmware_sig_url = os.environ["FIRMWARE_SIG_URL"]
    root_kernel_tags = os.getenv("KERNEL_TAGS", "").split(",")

    archs_env = os.getenv("KERNEL_ARCHITECTURES", "")
    arch_env = os.getenv("KERNEL_ARCH", "")
    if archs_env:
        root_kernel_archs = [a.strip() for a in archs_env.split(",") if a.strip()]
    elif arch_env:
        root_kernel_archs = [arch_env.strip()]
    else:
        print(
            "ERROR: KERNEL_ARCHITECTURES (or KERNEL_ARCH) must be set",
            file=sys.stderr,
        )
        sys.exit(1)
    return generate_builds(
        kernel_version=root_kernel_version,
        kernel_flavor=root_kernel_flavor,
        kernel_src_url=root_kernel_src_url,
        kernel_tags=root_kernel_tags,
        kernel_archs=root_kernel_archs,
        firmware_url=root_firmware_url,
        firmware_sig_url=root_firmware_sig_url,
        tag_suffix=get_branch_tag_suffix(),
    )


def generate_builds_from_matrix(matrix) -> list[str]:
    lines = []
    tag_suffix = get_branch_tag_suffix()
    builds = matrix["builds"]  # type: list[dict[str, Any]]
    for build in builds:
        build_version = build["version"]
        build_flavor = build["flavor"]
        build_source = build["source"]
        firmware_url = build["firmware_url"]
        firmware_sig_url = build["firmware_sig_url"]
        build_tags = build["tags"]
        # Matrix entries are always single-arch; wrap into a list for the
        # shared generate_builds helper.
        build_archs = [build["arch"]]
        lines += generate_builds(
            kernel_version=build_version,
            kernel_flavor=build_flavor,
            kernel_src_url=build_source,
            kernel_tags=build_tags,
            kernel_archs=build_archs,
            firmware_url=firmware_url,
            firmware_sig_url=firmware_sig_url,
            tag_suffix=tag_suffix,
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
