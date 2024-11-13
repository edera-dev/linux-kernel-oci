import json
import yaml
import subprocess
import urllib.request
from collections import OrderedDict
from functools import cache

from packaging.version import Version, parse

from util import matches_constraints, list_rsync_dir, format_image_name

try:
    from yaml import CLoader as Loader
except ImportError:
    from yaml import Loader

with open("config.yaml", "r") as f:
    CONFIG = yaml.load(f, Loader)

image_name_format = CONFIG["imageNameFormat"]


@cache
def get_current_kernel_releases():
    with urllib.request.urlopen("https://www.kernel.org/releases.json") as response:
        releases = json.load(response)
        return releases


@cache
def get_all_kernel_releases():
    releases = []
    for maybe_release_major in list_rsync_dir(
        "rsync://rsync.kernel.org/pub/linux/kernel/"
    ):
        if not (
            maybe_release_major.startswith("v") and maybe_release_major.endswith("x")
        ):
            continue
        for maybe_release_file in list_rsync_dir(
            "rsync://rsync.kernel.org/pub/linux/kernel/%s/" % maybe_release_major
        ):
            if not (
                maybe_release_file.startswith("linux-")
                and maybe_release_file.endswith(".tar.xz")
            ):
                continue
            kernel_version = maybe_release_file.replace("linux-", "").replace(
                ".tar.xz", ""
            )
            if "-" in kernel_version:
                continue
            releases.append(kernel_version)
    return releases


def merge_matrix(matrix_list):
    all_builds = OrderedDict()  # type: dict[str, dict[str, any]]
    for data in matrix_list:
        for item in data["builds"]:
            key = "%s::%s" % (item["version"], item["flavor"])
            if key not in all_builds:
                all_builds[key] = item
            else:
                for tag in item["tags"]:
                    if tag not in all_builds[key]["tags"]:
                        all_builds[key]["tags"].append(tag)
                for arch in item["architectures"]:
                    if arch not in all_builds[key]["architectures"]:
                        all_builds[key]["architectures"].append(arch)

    builds = list(all_builds.values())
    builds.sort(key=lambda build: parse(build["version"]))
    return {
        "builds": builds,
    }


def extract_base_images(matrix):
    images = []
    for build in matrix["builds"]:
        if "produces" not in build:
            raise Exception("build did not contain a produces key")
        for produce in build["produces"]:
            parts = produce.split(":")
            image = parts[0]
            if image not in images:
                images.append(image)
    return images


def find_existing_tags(images):
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


def validate_produce_conflicts(matrix):
    produce_check = {}

    for build in matrix["builds"]:
        for produce in build["produces"]:
            if produce in produce_check:
                raise Exception("ERROR: %s was produced more than once" % produce)
            else:
                produce_check[produce] = produce


def filter_new_builds(matrix):
    images = extract_base_images(matrix)
    existing = find_existing_tags(images)
    should_builds = []
    for build in matrix["builds"]:
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
    return {
        "builds": should_builds,
    }


def limit_gh_builds(matrix):
    builds = matrix["builds"]
    builds.sort(key=lambda build: parse(build["version"]))

    if len(builds) > 250:
        builds = builds[-250:]
    return {
        "builds": builds,
    }


def is_release_current(version: str):
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


def filter_matrix(matrix, constraint):
    builds = []
    for build in matrix["builds"]:
        version = build["version"]
        version_info = parse(version)
        flavor = build["flavor"]
        is_current_release = is_release_current(version)
        should_build = matches_constraints(
            version_info, flavor, constraint, is_current_release=is_current_release
        )
        if should_build:
            builds.append(build)
    return {
        "builds": builds,
    }


def filter_config_versions(matrix):
    builds = []
    for build in matrix["builds"]:
        version = build["version"]
        version_info = parse(version)
        flavor = build["flavor"]
        is_current_release = is_release_current(version)
        should_build = False
        for constraint in CONFIG["versions"]:
            if matches_constraints(
                version_info, flavor, constraint, is_current_release=is_current_release
            ):
                should_build = True
        if should_build:
            builds.append(build)

    return {
        "builds": builds,
    }


def generate_matrix(tags):
    unique_versions = list(set(tags.values()))
    unique_versions.sort(key=Version)

    version_builds = []

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

        src_url = "https://cdn.kernel.org/pub/linux/kernel/v%s.x/linux-%s.tar.xz" % (
            version_info.major,
            version_for_url,
        )
        for flavor_info in CONFIG["flavors"]:
            flavor = flavor_info["name"]
            if "constraints" in flavor_info and not matches_constraints(
                version_info, flavor, flavor_info["constraints"]
            ):
                continue

            produces = []
            for tag in version_tags:
                kernel_output = format_image_name(
                    image_name_format, flavor, version_info, "[flavor]-kernel", tag
                )
                kernel_sdk_output = format_image_name(
                    image_name_format, flavor, version_info, "[flavor]-kernel-sdk", tag
                )
                produces.append(kernel_output)
                produces.append(kernel_sdk_output)

            version_builds.append(
                {
                    "version": version,
                    "tags": version_tags,
                    "source": src_url,
                    "flavor": flavor,
                    "architectures": CONFIG["architectures"],
                    "produces": produces,
                }
            )

    matrix = {
        "builds": version_builds,
    }
    return matrix


def summarize_matrix(matrix):
    for build in matrix["builds"]:
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
            "build %s %s for %s with tags %s on %s"
            % (
                build["flavor"],
                build["version"],
                ", ".join(build["architectures"]),
                ", ".join(tags),
                ", ".join(image_names),
            )
        )


def generate_stable_matrix():
    current_kernel_releases = get_current_kernel_releases()
    latest_stable = current_kernel_releases["latest_stable"]["version"]

    known_releases = []

    for release in current_kernel_releases["releases"]:
        if (release["moniker"] in ["stable", "longterm"]) or release[
            "version"
        ] == latest_stable:
            known_releases.append(release["version"])

    tags = {}
    major_minors = {}

    for version in known_releases:
        parts = parse(version)
        if parts.major < 5:
            continue

        if version == latest_stable:
            tags["stable"] = version
        major = str(parts.major)
        major_minor = "%s.%s" % (parts.major, parts.minor)

        if major in tags:
            existing = tags[major]
            if parse(existing) < parts:
                tags[major] = version
        else:
            tags[major] = version

        if major_minor in tags:
            existing = tags[major_minor]
            if parse(existing) < parts:
                tags[major_minor] = version
                major_minors[major_minor] = version
        else:
            tags[major_minor] = version
            major_minors[major_minor] = version

    tags["latest"] = tags["stable"]

    for tag in list(tags.keys()):
        version = tags[tag]
        tags[version] = version
    return generate_matrix(tags)


def generate_backbuild_matrix():
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
