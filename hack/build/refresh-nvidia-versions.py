#!/usr/bin/env python3
"""Rewrite zone-nvidiagpu local_tags in config.yaml with the latest versions
published on https://www.nvidia.com/en-us/drivers/unix/.

Stdlib-only. Only the version digits in each of
the three matching lines change. If no new versions found, should not update the file.
Currently only supports amd64 drivers. A human must review the PR opened by the GH Action that runs this.
"""

import json
import re
import sys
import urllib.request
from pathlib import Path

NVIDIA_URL = "https://www.nvidia.com/en-us/drivers/unix/"
CONFIG_PATH = Path("config.yaml")

# NVIDIA_URL fills its version table client-side from this lookup service, so
# query it directly. Keep the per-label params in sync with the drvrLkupInputs
# entries for osCode "linux64" in that page's inline JS.
LOOKUP_URL = (
    "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/"
    "AjaxDriverService.php?func=DriverManualLookup"
    "&psid=133&pfid=1075&osID=12&languageCode=1033&isWHQL=0&dltype=-1&dch=0"
    "&upCRD=null&ctk=null&numberOfResults=1&"
)

# The three NVIDIA-page labels we care about, mapped to the lookup params for
# each. The labels are the literal text used in the trailing comment of each
# local_tags line in config.yaml. The script matches lines by the comment
# label, so the order in config.yaml is free.
LABELS = {
    "Latest Production Branch Version": "beta=0&qnf=0&sort1=",
    "Latest New Feature Branch Version": "beta=null&qnf=1&sort1=1",
    "Latest Beta Version": "beta=1&qnf=0&sort1=1",
}

VERSION_RE = re.compile(r"[0-9][0-9.]*[0-9]")


def fetch_latest_versions() -> dict[str, str]:
    versions = {}
    for label, params in LABELS.items():
        req = urllib.request.Request(
            LOOKUP_URL + params, headers={"User-Agent": "Mozilla/5.0"}
        )
        with urllib.request.urlopen(req) as resp:
            data = json.load(resp)
        try:
            assert data["Success"] == "1"
            info = data["IDS"][0]["downloadInfo"]
            assert info["OsCode"] == "linux64"
            # Version is a mangled form (595.1040 for 595.104.02); the page
            # itself prefers DisplayVersion.
            version = info["DisplayVersion"]
        except AssertionError, KeyError, IndexError, TypeError:
            raise RuntimeError(
                "Unexpected NVIDIA lookup response for %r: %s" % (label, data)
            )
        if not VERSION_RE.fullmatch(version):
            raise RuntimeError("Bad version %r for %r" % (version, label))
        versions[label] = version
    return versions


# Matches a local_tags line like:
#   - 'nvidia-580.126.18'   # Nvidia: "Latest Production Branch Version"
# Captures: prefix (everything up to and including the opening quote),
# the version digits, and suffix (closing quote onward).
LINE_RE = re.compile(
    r"^(?P<prefix>\s*-\s*['\"]nvidia-)(?P<version>[0-9][0-9.]*[0-9])(?P<suffix>['\"].*?\"(?P<label>[^\"]+)\".*)$"
)


def rewrite_config(versions: dict[str, str], path: Path = CONFIG_PATH) -> bool:
    original = path.read_text()
    new_lines = []
    changed = False
    seen_labels = set()
    for line in original.splitlines(keepends=True):
        m = LINE_RE.match(line.rstrip("\n"))
        if not m:
            new_lines.append(line)
            continue
        label = m.group("label")
        if label not in versions:
            new_lines.append(line)
            continue
        seen_labels.add(label)
        new_version = versions[label]
        if m.group("version") == new_version:
            new_lines.append(line)
            continue
        ending = "\n" if line.endswith("\n") else ""
        rewritten = m.group("prefix") + new_version + m.group("suffix") + ending
        new_lines.append(rewritten)
        changed = True
        print(
            "  %s: %s -> %s" % (label, m.group("version"), new_version),
            file=sys.stderr,
        )

    missing = set(versions) - seen_labels
    if missing:
        raise RuntimeError(
            "config.yaml is missing local_tags lines for: %s"
            % ", ".join(sorted(missing))
        )

    if changed:
        path.write_text("".join(new_lines))
    return changed


def main() -> int:
    versions = fetch_latest_versions()
    print("upstream versions:", file=sys.stderr)
    for label, ver in versions.items():
        print("  %s = %s" % (label, ver), file=sys.stderr)
    changed = rewrite_config(versions)
    print("changed" if changed else "no changes", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
