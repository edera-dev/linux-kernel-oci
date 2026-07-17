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
    version: Version,
    flavor: str,
    constraints: dict[str, any],
    is_current_release=None,
    arch: Optional[str] = None,
) -> bool:
    if "any" in constraints:
        for constraint in constraints["any"]:
            if matches_constraints(
                version,
                flavor,
                constraint,
                is_current_release=is_current_release,
                arch=arch,
            ):
                return True
        return False

    major_minor_series = "%s.%s" % (version.major, version.minor)
    major_series = str(version.major)

    flavors = maybe(constraints, "flavors")
    lower = maybe(constraints, "lower")
    only_series = maybe(constraints, "series")
    upper = maybe(constraints, "upper")
    exact = maybe(constraints, "exact")
    current = maybe(constraints, "current")
    arch_constraint = maybe(constraints, "arch")

    if lower is not None:
        lower = Version(lower)
    if upper is not None:
        upper = Version(upper)
    if exact is str:
        exact = [exact]

    applies = True

    if is_current_release is not None and current is not None:
        if is_current_release != current:
            applies = False

    if lower is None and upper is not None:
        if version > upper:
            applies = False

    if lower is not None and upper is None:
        if version < lower:
            applies = False

    if lower is not None and upper is not None:
        if version < lower or version > upper:
            applies = False

    if type(only_series) is str:
        only_series = [only_series]

    if only_series is not None and (
        (major_minor_series not in only_series) and (major_series not in only_series)
    ):
        applies = False

    if flavors is not None and flavor not in flavors:
        applies = False

    version_string = str(version)
    if exact is not None and not version_string in exact:
        applies = False

    if arch_constraint is not None and arch is not None:
        if type(arch_constraint) is str:
            arch_constraint = [arch_constraint]
        if arch not in arch_constraint:
            applies = False

    return applies


def list_remote_git_tags(url: str, attempts: int = 6) -> list[str]:
    # ls-remote fetches only the tag advertisement (protocol v2 filters it
    # server-side), so this avoids both a clone and rsync.kernel.org's
    # aggressive concurrent-connection cap. Retries cover transient network
    # failures, with stderr surfaced so the failure mode shows up in CI logs.
    for attempt in range(attempts):
        try:
            result = subprocess.run(
                ["git", "ls-remote", "--tags", "--refs", url],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                # git has no network timeout of its own, so without this a
                # hung connection would stall matrix generation until the CI
                # job limit instead of falling through to the retry loop.
                timeout=120,
            )
        except subprocess.TimeoutExpired:
            sys.stderr.write(
                "listing tags of %s timed out (attempt %d/%d)\n"
                % (url, attempt + 1, attempts)
            )
            if attempt + 1 < attempts:
                time.sleep(min(120, 10 * 2**attempt) + random.uniform(0, 5))
                continue
            raise
        if result.returncode == 0:
            break
        sys.stderr.write(
            "listing tags of %s failed (attempt %d/%d):\n%s\n"
            % (url, attempt + 1, attempts, result.stderr.decode("utf-8", "replace"))
        )
        if attempt + 1 < attempts:
            time.sleep(min(120, 10 * 2**attempt) + random.uniform(0, 5))
    result.check_returncode()
    tags = []
    for line in result.stdout.splitlines(keepends=False):
        # "<oid>\trefs/tags/<tag>"
        parts = line.decode("utf-8").strip().split("\t")
        if len(parts) != 2 or not parts[1].startswith("refs/tags/"):
            continue
        tags.append(parts[1][len("refs/tags/") :])
    return tags


def parse_text_bool(text: str) -> bool:
    return text.lower() in ["1", "true", "yes"]


def parse_text_constraint(text: str) -> dict[str, any]:
    constraint = {}
    for item in text.split(";"):
        item = item.strip()
        parts = item.split("=", maxsplit=1)
        if len(parts) != 2:
            parts = [parts[0], ""]
        key = parts[0]
        value = parts[1]
        if key == "current":
            constraint[key] = parse_text_bool(value)
        elif key == "lower" or key == "upper":
            constraint[key] = value
        elif (
            key == "flavors"
            or key == "flavor"
            or key == "series"
            or key == "exact"
            or key == "arch"
        ):
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
