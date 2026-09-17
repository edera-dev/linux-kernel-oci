import os
import random
import re
import sys
import time
from typing import Optional

from packaging.version import Version
import subprocess


def get_branch_tag_suffix() -> Optional[str]:
    ref_name = os.getenv("GITHUB_REF_NAME", "")
    if not ref_name or ref_name == "main":
        return None
    return re.sub(r"[^a-zA-Z0-9._-]", "_", ref_name)


def format_image_name(
    image_name_format: str, flavor: str, version_info: Version, name: str, tag: str
) -> str:
    result = image_name_format
    result = result.replace("[image]", name)
    result = result.replace("[flavor]", flavor)
    result = result.replace("[major]", str(version_info.major))
    result = result.replace("[minor]", str(version_info.minor))
    result = result.replace("[patch]", str(version_info.micro))
    result = result.replace(
        "[series]", "%s.%s" % (version_info.major, version_info.minor)
    )
    result = result.replace("[tag]", tag)
    return result


def maybe(m: dict[str, any], k: str, default_value: any = None) -> any:
    if k in m:
        return m[k]
    else:
        return default_value


def matches_constraints(
    branch: str,
    flavor: str,
    constraints: dict[str, any],
    arch: Optional[str] = None,
) -> bool:
    """Does a (branch, flavor, arch) build match a constraint block?

    Constraints are matched on names, not version ranges: the kernel version is
    a property of whatever edera-dev/linux branch is being built, not something
    this repo picks, so anything that wants to scope itself to a particular
    kernel says which branch it means.

    Recognized keys: `branches`, `flavors`, `arch`, and `any` (a list of
    constraint blocks, matching if any one of them does). A key that is absent
    places no restriction; an empty constraint block matches everything.
    """
    if "any" in constraints:
        for constraint in constraints["any"]:
            if matches_constraints(branch, flavor, constraint, arch=arch):
                return True
        return False

    branches = maybe(constraints, "branches")
    flavors = maybe(constraints, "flavors")
    arch_constraint = maybe(constraints, "arch")

    if type(branches) is str:
        branches = [branches]
    if type(flavors) is str:
        flavors = [flavors]
    if type(arch_constraint) is str:
        arch_constraint = [arch_constraint]

    if branches is not None and branch is not None and branch not in branches:
        return False

    if flavors is not None and flavor not in flavors:
        return False

    if arch_constraint is not None and arch is not None and arch not in arch_constraint:
        return False

    return True


def _git_ls_remote(
    args: list[str], url: str, patterns: list[str] = [], attempts: int = 6
) -> bytes:
    # ls-remote fetches only the ref advertisement (protocol v2 filters it
    # server-side), so this avoids a clone entirely. Retries cover transient
    # network failures, with stderr surfaced so the failure mode shows up in CI
    # logs.
    for attempt in range(attempts):
        try:
            result = subprocess.run(
                ["git", "ls-remote", *args, url, *patterns],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                # git has no network timeout of its own, so without this a
                # hung connection would stall matrix generation until the CI
                # job limit instead of falling through to the retry loop.
                timeout=120,
            )
        except subprocess.TimeoutExpired:
            sys.stderr.write(
                "listing refs of %s timed out (attempt %d/%d)\n"
                % (url, attempt + 1, attempts)
            )
            if attempt + 1 < attempts:
                time.sleep(min(120, 10 * 2**attempt) + random.uniform(0, 5))
                continue
            raise
        if result.returncode == 0:
            break
        sys.stderr.write(
            "listing refs of %s failed (attempt %d/%d):\n%s\n"
            % (url, attempt + 1, attempts, result.stderr.decode("utf-8", "replace"))
        )
        if attempt + 1 < attempts:
            time.sleep(min(120, 10 * 2**attempt) + random.uniform(0, 5))
    result.check_returncode()
    return result.stdout


def list_remote_git_tags(url: str, attempts: int = 6) -> list[str]:
    stdout = _git_ls_remote(["--tags", "--refs"], url, attempts=attempts)
    tags = []
    for line in stdout.splitlines(keepends=False):
        # "<oid>\trefs/tags/<tag>"
        parts = line.decode("utf-8").strip().split("\t")
        if len(parts) != 2 or not parts[1].startswith("refs/tags/"):
            continue
        tags.append(parts[1][len("refs/tags/") :])
    return tags


def resolve_remote_branch(url: str, branch: str, attempts: int = 6) -> str:
    """Resolve a branch name on a remote to the commit it currently points at.

    Matching is against refs/heads/<branch> exactly: `--heads <branch>` would
    also match a ref whose name merely ends in the same path component, and
    silently building the wrong branch is far worse than failing here.
    """
    ref = "refs/heads/%s" % branch
    stdout = _git_ls_remote(["--heads"], url, patterns=[ref], attempts=attempts)
    for line in stdout.splitlines(keepends=False):
        parts = line.decode("utf-8").strip().split("\t")
        if len(parts) != 2:
            continue
        if parts[1] == ref:
            return parts[0]
    raise Exception("branch %s does not exist on %s" % (branch, url))


def parse_text_bool(text: str) -> bool:
    return text.lower() in ["1", "true", "yes"]


def parse_text_constraint(text: str) -> dict[str, any]:
    """Parse a build-spec constraint string, e.g. "branch=mainline;flavor=zone".

    Keys mirror the constraint blocks in config.yaml. `branch` and `flavor` are
    accepted as singular spellings of `branches` and `flavors`; values are
    comma-separated.
    """
    constraint = {}
    for item in text.split(";"):
        item = item.strip()
        if not item:
            continue
        parts = item.split("=", maxsplit=1)
        if len(parts) != 2:
            parts = [parts[0], ""]
        key = parts[0]
        value = parts[1]
        if key in ["branch", "branches", "flavor", "flavors", "arch"]:
            if key == "branch":
                key = "branches"
            if key == "flavor":
                key = "flavors"
            constraint[key] = value.split(",")
        else:
            raise Exception("unknown constraint key: %s" % key)
    return constraint


def smart_script_split(
    command: list[str], description: Optional[str] = None
) -> list[str]:
    sections = []
    current = []
    is_potentially_value = False
    for item in command:
        arm_potentially_value = False
        if item.startswith("-"):
            if len(current) > 0:
                sections.append(current)
                current = []
                is_potentially_value = False
            arm_potentially_value = True
        current.append(item)
        if is_potentially_value:
            is_potentially_value = False
            sections.append(current)
            current = []
        if arm_potentially_value:
            is_potentially_value = True
    if len(current) > 0:
        sections.append(current)
    lines = []
    if description is not None:
        lines.append("# %s" % description)
    for i, section in enumerate(sections):
        line = " ".join(section)
        if i != 0:
            line = "  " + line
        if i != len(sections) - 1:
            line += " \\"
        lines.append(line)
    return lines
