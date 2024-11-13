from typing import Optional

from packaging.version import Version
import subprocess


def format_image_name(
    image_name_format: str, flavor: str, version_info: Version, name: str, tag: str
):
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


def maybe(m: dict[str, any], k: str, default_value: any = None):
    if k in m:
        return m[k]
    else:
        return default_value


def matches_constraints(
    version: Version, flavor: str, constraints: dict[str, any], is_current_release=None
) -> bool:
    major_minor_series = "%s.%s" % (version.major, version.minor)
    major_series = str(version.major)

    flavors = maybe(constraints, "flavors")
    lower = maybe(constraints, "lower")
    only_series = maybe(constraints, "series")
    upper = maybe(constraints, "upper")
    exact = maybe(constraints, "exact")
    current = maybe(constraints, "current")

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

    if only_series is not None and (
        (major_minor_series not in only_series) and (major_series not in only_series)
    ):
        applies = False

    if flavors is not None and flavor not in flavors:
        applies = False

    version_string = str(version)
    if exact is not None and not version_string in exact:
        applies = False

    return applies


def list_rsync_dir(url: str):
    result = subprocess.run(
        ["rsync", "--list-only", "--out-format='%n'", url],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    result.check_returncode()
    files = []
    for line in result.stdout.splitlines(keepends=False):
        line = line.decode("utf-8")
        if len(line.strip()) == 0:
            continue
        if line.startswith("MOTD:"):
            continue
        file_name = str(line.split(" ")[-1])
        if file_name != ".":
            files.append(file_name)
    return files


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
        elif key == "flavors" or key == "flavor" or key == "series" or key == "exact":
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
