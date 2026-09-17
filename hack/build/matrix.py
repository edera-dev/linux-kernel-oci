import os
import random
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import OrderedDict
from functools import cache

import yaml
from packaging.version import Version, parse

from util import (
    format_image_name,
    list_remote_git_tags,
    matches_constraints,
    maybe,
    resolve_remote_branch,
)

try:
    from yaml import CLoader as Loader
except ImportError:
    from yaml import Loader

with open("config.yaml", "r") as f:
    CONFIG = yaml.load(f, Loader)

image_name_format = CONFIG["imageNameFormat"]

KERNEL_CDN = "https://cdn.kernel.org/pub/linux/kernel"

GITHUB_PREFIX = "https://github.com/"

# git abbreviates to 12 characters for a repository the size of linux.git, and
# the kernel's own scripts/setlocalversion does the same. Shorter prefixes are
# not safely unique across the millions of objects in that history, and an
# image tag that silently aliases two commits is worse than a long tag.
SHORT_COMMIT_LENGTH = 12


@cache
def source_repo() -> str:
    return CONFIG["source"]["repo"].rstrip("/")


@cache
def _github_slug() -> str:
    """The `owner/name` of the configured source repo.

    Resolving a branch to a commit only needs git, but reading one file out of
    that commit (the Makefile, for the kernel version) and fetching the source
    archive both go through GitHub's HTTP endpoints. Moving to a different
    forge means teaching these two URL builders about it, which is why the
    assumption fails loudly here rather than 404ing later.
    """
    repo = source_repo()
    if not repo.startswith(GITHUB_PREFIX):
        raise Exception(
            "source.repo must be a https://github.com/ URL, got %s "
            "(archive and raw-file URLs are GitHub-specific)" % repo
        )
    slug = repo[len(GITHUB_PREFIX) :].strip("/")
    if slug.endswith(".git"):
        slug = slug[: -len(".git")]
    if slug.count("/") != 1:
        raise Exception("source.repo is not an owner/name GitHub URL: %s" % repo)
    return slug


def source_archive_url(commit: str) -> str:
    """Tarball of the tree at `commit`.

    Addressed by commit rather than by branch so the URL is immutable: buildkit
    caches the `ADD` by URL, and a branch-addressed URL would let a stale cache
    entry silently serve the wrong source. The archive carries no .git
    directory, so scripts/setlocalversion contributes nothing and `uname -r`
    stays the plain kernel version, exactly as it did with kernel.org tarballs.
    """
    return "%s%s/archive/%s.tar.gz" % (GITHUB_PREFIX, _github_slug(), commit)


def source_raw_url(commit: str, path: str) -> str:
    return "https://raw.githubusercontent.com/%s/%s/%s" % (
        _github_slug(),
        commit,
        path,
    )


def fetch_url_text(url: str, attempts: int = 6) -> str:
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                return response.read().decode("utf-8")
        except (urllib.error.URLError, TimeoutError) as error:
            sys.stderr.write(
                "fetching %s failed (attempt %d/%d): %s\n"
                % (url, attempt + 1, attempts, error)
            )
            if attempt + 1 >= attempts:
                raise
            time.sleep(min(120, 10 * 2**attempt) + random.uniform(0, 5))


MAKEFILE_VERSION_FIELD = re.compile(
    r"^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION)\s*=\s*(.*?)\s*$"
)


def kernel_version_from_makefile(makefile: str) -> str:
    """The kernel version a Makefile declares, e.g. "6.18.52" or "7.3.0-rc3".

    The Edera branches carry no release tags of their own, so the Makefile is
    the authority on what version a branch currently is. These are the same
    four fields the kernel's own build uses to form KERNELRELEASE, so what we
    tag an image with is what the kernel inside it reports.
    """
    fields = {}
    for line in makefile.splitlines():
        match = MAKEFILE_VERSION_FIELD.match(line)
        if match and match.group(1) not in fields:
            fields[match.group(1)] = match.group(2)
    for required in ("VERSION", "PATCHLEVEL"):
        if not fields.get(required):
            raise Exception("kernel Makefile has no %s" % required)
    version = "%s.%s.%s" % (
        fields["VERSION"],
        fields["PATCHLEVEL"],
        fields.get("SUBLEVEL") or "0",
    )
    # "-rc3" and friends attach directly, matching how the kernel spells it.
    return version + fields.get("EXTRAVERSION", "")


@cache
def resolve_branches() -> tuple[dict[str, any], ...]:
    """Resolve every configured branch to a commit and a kernel version.

    Everything downstream keys off this: the commit fixes the source archive
    and the immutable image tag, the version fixes the moving tags.
    """
    repo = source_repo()
    resolved = []
    for branch_info in CONFIG["branches"]:
        name = branch_info["name"]
        ref = branch_info["ref"]
        commit = resolve_remote_branch(repo, ref)
        version = kernel_version_from_makefile(
            fetch_url_text(source_raw_url(commit, "Makefile"))
        )
        resolved.append(
            {
                "name": name,
                "ref": ref,
                "repo": repo,
                "commit": commit,
                "short_commit": commit[:SHORT_COMMIT_LENGTH],
                "version": version,
                "aliases": list(maybe(branch_info, "aliases", [])),
            }
        )
    return tuple(resolved)


def branch_tags(branch: dict[str, any]) -> list[str]:
    """Every tag a build of this branch publishes, immutable one first.

    The `<version>-g<commit>` tag is unique to one commit and is never reused,
    which is both what makes a rebuild detectable (see filter_new_builds) and
    what lets a consumer pin to an exact tree. Everything after it moves.
    """
    version = branch["version"]
    version_info = parse(version)
    tags = ["%s-g%s" % (version, branch["short_commit"]), version]
    # A prerelease must not claim the series tag: `7.3` belongs to 7.3 proper,
    # not to the 7.3-rc3 that precedes it.
    if not version_info.is_prerelease:
        tags.append("%s.%s" % (version_info.major, version_info.minor))
    tags.append(branch["name"])
    tags += branch["aliases"]

    unique = []
    for tag in tags:
        if tag not in unique:
            unique.append(tag)
    return unique


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
def get_all_firmware_releases() -> list[str]:
    # Snapshot tags are pure YYYYMMDD and map 1:1 to the published
    # linux-firmware-YYYYMMDD.tar.xz artifacts, so lexicographic sort is
    # chronological. This is the one remaining kernel.org dependency, and it
    # has nothing to do with the kernel source.
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
    # produces are intentionally shared across arches for the same
    # (branch, flavor); each arch build pushes its single-platform image by
    # digest, and the merge step later tags the combined manifest list. Only
    # flag when the *same* image:tag is claimed by two different
    # (branch, flavor) combinations -- most plausibly two branches that have
    # converged on one version, or that both claim an alias like `latest`.
    produce_owner = {}

    for build in builds:
        owner = "%s::%s" % (build["branch"], build["flavor"])
        for produce in build["produces"]:
            if produce in produce_owner and produce_owner[produce] != owner:
                raise Exception(
                    "ERROR: %s is produced by both %s and %s"
                    % (produce, produce_owner[produce], owner)
                )
            produce_owner[produce] = owner


def filter_new_builds(builds: list[dict[str, any]]) -> list[dict[str, any]]:
    """Drop builds whose every published tag is already in the registry.

    Because each build's tag list leads with `<version>-g<commit>`, a branch
    that has moved always looks new here even when its kernel version has not
    changed -- the normal case for a downstream branch picking up a patch
    between upstream releases.
    """
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


def filter_matrix(
    builds: list[dict[str, any]], constraint: dict[str, any]
) -> list[dict[str, any]]:
    output_builds = []
    for build in builds:
        if matches_constraints(
            build["branch"],
            build["flavor"],
            constraint,
            arch=build.get("arch"),
        ):
            output_builds.append(build)
    return output_builds


def generate_matrix(branches: list[dict[str, any]]) -> list[dict[str, any]]:
    version_builds = []

    # TODO later on we could get cute and let the config drive
    # which firmware snapshot to use - but as far as the official firmware goes
    # latest should be fine/preferred.
    # https://www.kernel.org/doc/html/latest/driver-api/firmware/firmware-usage-guidelines.html
    all_firmware_releases = get_all_firmware_releases()
    latest_firmware = all_firmware_releases[0]

    firmware_url = "%s/firmware/linux-firmware-%s.tar.xz" % (
        KERNEL_CDN,
        latest_firmware,
    )

    firmware_sig_url = "%s/firmware/linux-firmware-%s.tar.sign" % (
        KERNEL_CDN,
        latest_firmware,
    )

    for branch in branches:
        version = branch["version"]
        version_info = parse(version)
        src_url = source_archive_url(branch["commit"])
        base_tags = branch_tags(branch)

        for flavor_info in CONFIG["flavors"]:
            flavor = flavor_info["name"]
            if "constraints" in flavor_info and not matches_constraints(
                branch["name"], flavor, flavor_info["constraints"]
            ):
                continue

            architectures = flavor_architectures(flavor_info)

            # A flavor with local_tags publishes one distinct image per tag
            # (today: one per NVIDIA driver series), each carrying the whole
            # tag set with the local tag appended.
            local_tags = maybe(flavor_info, "local_tags", [None])
            for local_tag in local_tags:
                if local_tag is None:
                    build_version = version
                    tags = list(base_tags)
                else:
                    build_version = "%s+%s" % (version, local_tag)
                    tags = ["%s-%s" % (tag, local_tag) for tag in base_tags]

                produces = []
                for tag in tags:
                    produces.append(
                        format_image_name(
                            image_name_format,
                            flavor,
                            version_info,
                            "[flavor]-kernel",
                            tag,
                        )
                    )
                    produces.append(
                        format_image_name(
                            image_name_format,
                            flavor,
                            version_info,
                            "[flavor]-kernel-sdk",
                            tag,
                        )
                    )

                for arch in architectures:
                    version_builds.append(
                        {
                            "branch": branch["name"],
                            "ref": branch["ref"],
                            "repo": branch["repo"],
                            "commit": branch["commit"],
                            "version": build_version,
                            "firmware_url": firmware_url,
                            "firmware_sig_url": firmware_sig_url,
                            "tags": tags,
                            "source": src_url,
                            "flavor": flavor,
                            "arch": arch,
                            "produces": produces,
                        }
                    )
    return version_builds


def generate_full_matrix() -> list[dict[str, any]]:
    return generate_matrix(list(resolve_branches()))


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
            "build %s %s (%s @ %s) for %s with tags %s to %s on %s"
            % (
                build["flavor"],
                build["version"],
                build["branch"],
                build["commit"][:SHORT_COMMIT_LENGTH],
                build["arch"],
                ", ".join(tags),
                ", ".join(image_names),
                build["runner"],
            )
        )


def pick_runner(build: dict[str, any]) -> str:
    for runner in CONFIG["runners"]:
        if matches_constraints(
            build["branch"],
            build["flavor"],
            runner,
            arch=build["arch"],
        ):
            return runner["name"]
    raise Exception("No runner found for build %s" % build)


def fill_runners(builds: list[dict[str, any]]):
    for build in builds:
        build["runner"] = pick_runner(build)


def sort_matrix(builds: list[dict[str, any]]):
    builds.sort(
        key=lambda build: (Version(build["version"]), build["flavor"], build["arch"])
    )


def generate_merges(builds: list[dict[str, any]]) -> list[dict[str, any]]:
    """Group per-arch builds into one merge entry per (branch, version, flavor).

    The merge job runs after all per-arch build jobs for that group complete;
    it stitches the single-platform pushes into a manifest list per produced
    image:tag.
    """
    merges = OrderedDict()  # type: dict[str, dict[str, any]]
    for build in builds:
        key = "%s::%s::%s" % (build["branch"], build["version"], build["flavor"])
        if key not in merges:
            merges[key] = {
                "branch": build["branch"],
                "version": build["version"],
                "flavor": build["flavor"],
                "tags": list(build["tags"]),
                "produces": list(build["produces"]),
                "archs": [build["arch"]],
                # Carried for SBOM generation in the merge job; identical across
                # archs for a given (branch, flavor).
                "repo": build["repo"],
                "ref": build["ref"],
                "commit": build["commit"],
                "source": build["source"],
                "firmware_url": build["firmware_url"],
            }
        else:
            if build["arch"] not in merges[key]["archs"]:
                merges[key]["archs"].append(build["arch"])
    return list(merges.values())
