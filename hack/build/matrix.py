import json
import os
import re

import yaml
import subprocess
import urllib.request
from collections import OrderedDict
from functools import cache

from packaging.version import Version, parse

from util import matches_constraints, list_remote_git_tags, format_image_name

try:
    from yaml import CLoader as Loader
except ImportError:
    from yaml import Loader

with open("config.yaml", "r") as f:
    CONFIG = yaml.load(f, Loader)

image_name_format = CONFIG["imageNameFormat"]


@cache
def default_architectures() -> list[str]:
    architecture_env = os.getenv("KERNEL_ARCHITECTURES", "")
    if len(architecture_env) > 0:
        return [arch.strip() for arch in architecture_env.split(",")]

    architectures = CONFIG["architectures"]  # type: list[str]
    return architectures


def flavor_architectures(flavor_info: dict[str, any]) -> list[str]:
    """Per-flavor architectures override; falls back to the global default."""
    if "architectures" in flavor_info:
        return flavor_info["architectures"]
    return default_architectures()


@cache
def get_current_kernel_releases() -> dict[str, any]:
    with urllib.request.urlopen("https://www.kernel.org/releases.json") as response:
        releases = json.load(response)
        return releases


@cache
def get_all_kernel_releases() -> list[str]:
    # Release tags (vX.Y[.Z]) map 1:1 to the published linux-X.Y[.Z].tar.xz
    # artifacts; "-" excludes -rc and other pre-release tags. Tags only reach
    # back to v2.6.11, but nothing anywhere near that old is buildable here.
    releases = []
    for tag in list_remote_git_tags(
        "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
    ):
        if not tag.startswith("v"):
            continue
        kernel_version = tag[1:]
        if "-" in kernel_version:
            continue
        releases.append(kernel_version)
    return releases


@cache
def get_all_firmware_releases() -> list[str]:
    # Snapshot tags are pure YYYYMMDD and map 1:1 to the published
    # linux-firmware-YYYYMMDD.tar.xz artifacts, so lexicographic sort is
    # chronological.
    snapshots = []
    for tag in list_remote_git_tags(
        "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git"
    ):
        if not re.fullmatch(r"[0-9]{8}", tag):
            continue
        snapshots.append(tag)
    snapshots.sort()
    snapshots.reverse()
    return snapshots


def merge_matrix(matrix_list: list[list[dict[str, any]]]) -> list[dict[str, any]]:
    all_builds = OrderedDict()  # type: dict[str, dict[str, any]]
    for builds in matrix_list:
        for item in builds:
            key = "%s::%s::%s" % (item["version"], item["flavor"], item["arch"])
            if key not in all_builds:
                all_builds[key] = item
            else:
                for tag in item["tags"]:
                    if tag not in all_builds[key]["tags"]:
                        all_builds[key]["tags"].append(tag)

    builds = list(all_builds.values())
    builds.sort(key=lambda build: parse(build["version"]))
    return builds


def extract_base_images(builds: list[dict[str, any]]):
    images = []
    for build in builds:
        if "produces" not in build:
            raise Exception("build did not contain a produces key")
        for produce in build["produces"]:
            parts = produce.split(":")
            image = parts[0]
            if image not in images:
                images.append(image)
    return images


def find_existing_tags(images: list[str]) -> dict[str, list[str]]:
    existing = {}
    for image in images:
        # ignore return code, we just want stdout
        result = subprocess.run(
            ["crane", "ls", "-O", image],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        tags = result.stdout.decode("utf-8").splitlines(keepends=False)
        existing[image] = tags
    return existing


def validate_produce_conflicts(builds: list[dict[str, any]]):
    # produces are intentionally shared across arches for the same (version, flavor);
    # each arch build pushes its single-platform image by digest, and the merge step
    # later tags the combined manifest list. Only flag when the *same* image:tag is
    # claimed by two different (version, flavor) combinations.
    produce_owner = {}

    for build in builds:
        owner = "%s::%s" % (build["version"], build["flavor"])
        for produce in build["produces"]:
            if produce in produce_owner and produce_owner[produce] != owner:
                raise Exception(
                    "ERROR: %s is produced by both %s and %s"
                    % (produce, produce_owner[produce], owner)
                )
            produce_owner[produce] = owner


def filter_new_builds(builds: list[dict[str, any]]) -> list[dict[str, any]]:
    images = extract_base_images(builds)
    existing = find_existing_tags(images)
    should_builds = []
    for build in builds:
        should_build = False
        for produce in build["produces"]:
            parts = produce.split(":")
            image = parts[0]
            tag = parts[1]
            if image not in existing:
                should_build = True
            elif tag not in existing[image]:
                should_build = True
        if should_build:
            should_builds.append(build)
    return should_builds


def limit_gh_builds(builds: list[dict[str, any]]) -> list[dict[str, any]]:
    builds.sort(key=lambda build: parse(build["version"]))

    if len(builds) > 250:
        builds = builds[-250:]
    return builds


def is_release_current(version: str) -> bool:
    current_kernel_releases = get_current_kernel_releases()
    latest_stable = current_kernel_releases["latest_stable"]["version"]
    is_current = False
    if latest_stable is not None and version == latest_stable:
        is_current = True
        return is_current
    for release in current_kernel_releases["releases"]:
        if not release["moniker"] in ["stable", "longterm"]:
            continue
        if release["version"] == version:
            is_current = True
            break
    return is_current


def filter_matrix(
    builds: list[dict[str, any]], constraint: dict[str, any]
) -> list[dict[str, any]]:
    output_builds = []
    for build in builds:
        version = build["version"]
        version_info = parse(version)
        flavor = build["flavor"]
        is_current_release = is_release_current(version_info.base_version)
        should_build = matches_constraints(
            version_info,
            flavor,
            constraint,
            is_current_release=is_current_release,
            arch=build.get("arch"),
        )
        if should_build:
            output_builds.append(build)
    return output_builds


def filter_config_versions(builds: list[dict[str, any]]) -> list[dict[str, any]]:
    output_builds = []
    for build in builds:
        version = build["version"]
        version_info = parse(version)
        flavor = build["flavor"]
        is_current_release = is_release_current(version_info.base_version)
        should_build = False
        for constraint in CONFIG["versions"]:
            if matches_constraints(
                version_info, flavor, constraint, is_current_release=is_current_release
            ):
                should_build = True
        if should_build:
            output_builds.append(build)

    return output_builds


def generate_matrix(tags: dict[str, str]) -> list[dict[str, any]]:
    unique_versions = list(set(tags.values()))
    unique_versions.sort(key=Version)

    version_builds = []

    kernel_cdn = "https://cdn.kernel.org/pub/linux/kernel"

    # TODO later on we could get cute and let the config drive
    # which firmware snapshot to use - but as far as the official firmware goes
    # latest should be fine/preferred.
    # https://www.kernel.org/doc/html/latest/driver-api/firmware/firmware-usage-guidelines.html
    all_firmware_releases = get_all_firmware_releases()
    latest_firmware = all_firmware_releases[0]

    firmware_url = "%s/firmware/linux-firmware-%s.tar.xz" % (
        kernel_cdn,
        latest_firmware,
    )

    firmware_sig_url = "%s/firmware/linux-firmware-%s.tar.sign" % (
        kernel_cdn,
        latest_firmware,
    )

    for version in unique_versions:
        version_tags = []
        for tag in tags:
            tag_version = tags[tag]
            if tag_version == version:
                version_tags.append(tag)
        version_info = parse(version)

        version_for_url = version
        if version_info.micro == 0:
            version_for_url = "%s.%s" % (version_info.major, version_info.minor)

        src_url = "%s/v%s.x/linux-%s.tar.xz" % (
            kernel_cdn,
            version_info.major,
            version_for_url,
        )
        for flavor_info in CONFIG["flavors"]:
            flavor = flavor_info["name"]
            if "constraints" in flavor_info and not matches_constraints(
                version_info, flavor, flavor_info["constraints"]
            ):
                continue

            architectures = flavor_architectures(flavor_info)

            if "local_tags" in flavor_info:
                for local_tag in flavor_info["local_tags"]:
                    produces = []
                    local_version_tags = []
                    for tag in version_tags:
                        local_append = tag + "-" + local_tag
                        local_version_tags.append(local_append)
                        kernel_output = format_image_name(
                            image_name_format,
                            flavor,
                            version_info,
                            "[flavor]-kernel",
                            local_append,
                        )
                        kernel_sdk_output = format_image_name(
                            image_name_format,
                            flavor,
                            version_info,
                            "[flavor]-kernel-sdk",
                            local_append,
                        )
                        produces.append(kernel_output)
                        produces.append(kernel_sdk_output)
                    for arch in architectures:
                        version_builds.append(
                            {
                                "version": version + "+" + local_tag,
                                "firmware_url": firmware_url,
                                "firmware_sig_url": firmware_sig_url,
                                "tags": local_version_tags,
                                "source": src_url,
                                "flavor": flavor,
                                "arch": arch,
                                "produces": produces,
                            }
                        )
            else:
                produces = []
                for tag in version_tags:
                    kernel_output = format_image_name(
                        image_name_format, flavor, version_info, "[flavor]-kernel", tag
                    )
                    kernel_sdk_output = format_image_name(
                        image_name_format,
                        flavor,
                        version_info,
                        "[flavor]-kernel-sdk",
                        tag,
                    )
                    produces.append(kernel_output)
                    produces.append(kernel_sdk_output)
                for arch in architectures:
                    version_builds.append(
                        {
                            "version": version,
                            "firmware_url": firmware_url,
                            "firmware_sig_url": firmware_sig_url,
                            "tags": version_tags,
                            "source": src_url,
                            "flavor": flavor,
                            "arch": arch,
                            "produces": produces,
                        }
                    )
    return version_builds


def summarize_matrix(builds: list[dict[str, any]]):
    for build in builds:
        tags = []
        image_names = []
        for produce in build["produces"]:
            tag = produce.split(":")[-1]
            image_name = produce.split(":")[-2]
            if tag not in tags:
                tags.append(tag)
            if image_name not in image_names:
                image_names.append(image_name)
        tags.sort()
        print(
            "build %s %s for %s with tags %s to %s on %s"
            % (
                build["flavor"],
                build["version"],
                build["arch"],
                ", ".join(tags),
                ", ".join(image_names),
                build["runner"],
            )
        )


def build_release_tags(versions: list[str]) -> dict[str, str]:
    tags = {}
    for raw_version in versions:
        parsed_ver = parse(raw_version)
        # Hardcode skip of pre-5.x.x kernels
        if parsed_ver.major < 5:
            print(f"skipping {raw_version}, too old to support")
            continue
        major = str(parsed_ver.major)
        major_minor = "%s.%s" % (parsed_ver.major, parsed_ver.minor)
        if major not in tags or parse(tags[major]) < parsed_ver:
            tags[major] = raw_version
        if major_minor not in tags or parse(tags[major_minor]) < parsed_ver:
            tags[major_minor] = raw_version
    for tag in list(tags.keys()):
        tags[tags[tag]] = tags[tag]
    return tags


def generate_stable_matrix() -> list[dict[str, any]]:
    current_kernel_releases = get_current_kernel_releases()
    latest_stable = current_kernel_releases["latest_stable"]["version"]
    versions = [
        r["version"]
        for r in current_kernel_releases["releases"]
        if r["moniker"] in ["stable", "longterm"]
    ]
    tags = build_release_tags(versions)
    tags["stable"] = latest_stable
    tags["latest"] = latest_stable
    return generate_matrix(tags)


def generate_lts_matrix() -> list[dict[str, any]]:
    current_kernel_releases = get_current_kernel_releases()
    versions = [
        r["version"]
        for r in current_kernel_releases["releases"]
        if r["moniker"] == "longterm"
    ]
    return generate_matrix(build_release_tags(versions))


def generate_backbuild_matrix() -> list[dict[str, any]]:
    tags = {}
    major_minors = {}

    all_releases = get_all_kernel_releases()
    for version in all_releases:
        parts = parse(version)
        major_minor = "%s.%s" % (parts.major, parts.minor)

        if major_minor in tags:
            existing = tags[major_minor]
            if parse(existing) < parts:
                tags[major_minor] = version
                major_minors[major_minor] = version
        else:
            tags[major_minor] = version
            major_minors[major_minor] = version

    for tag in list(tags.keys()):
        version = tags[tag]
        tags[version] = version

    current_kernel_releases = get_current_kernel_releases()
    for release in current_kernel_releases["releases"]:
        if not release["moniker"] in ["stable", "longterm"]:
            continue
        for key in list(tags.keys()):
            if tags[key] == release["version"]:
                tags.pop(key)
        for key in list(major_minors.keys()):
            if major_minors[key] == release["version"]:
                major_minors.pop(key)
        parts = parse(release["version"])
        major_minor = "%s.%s" % (parts.major, parts.minor)
        if major_minor in major_minors:
            major_minors.pop(major_minor)
        if major_minor in tags:
            tags.pop(major_minor)
    return generate_matrix(tags)


def pick_runner(build: dict[str, any]) -> str:
    version: str = build["version"]
    version_info: Version = parse(version)
    flavor: str = build["flavor"]
    arch: str = build["arch"]
    for runner in CONFIG["runners"]:
        if matches_constraints(
            version_info,
            flavor,
            runner,
            is_current_release=is_release_current(version_info.base_version),
            arch=arch,
        ):
            return runner["name"]
    raise Exception("No runner found for build %s" % build)


def fill_runners(builds: list[dict[str, any]]):
    for build in builds:
        build["runner"] = pick_runner(build)


def sort_matrix(builds: list[dict[str, any]]):
    builds.sort(key=lambda build: Version(build["version"]))


def generate_merges(builds: list[dict[str, any]]) -> list[dict[str, any]]:
    """Group per-arch builds into one merge entry per (version, flavor).

    The merge job runs after all per-arch build jobs for that (version, flavor)
    complete; it stitches the single-platform pushes into a manifest list per
    produced image:tag.
    """
    merges = OrderedDict()  # type: dict[str, dict[str, any]]
    for build in builds:
        key = "%s::%s" % (build["version"], build["flavor"])
        if key not in merges:
            merges[key] = {
                "version": build["version"],
                "flavor": build["flavor"],
                "tags": list(build["tags"]),
                "produces": list(build["produces"]),
                "archs": [build["arch"]],
                # Carried for SBOM generation in the merge job; identical across
                # archs for a given (version, flavor).
                "source": build["source"],
                "firmware_url": build["firmware_url"],
            }
        else:
            if build["arch"] not in merges[key]["archs"]:
                merges[key]["archs"].append(build["arch"])
    return list(merges.values())
