#!/usr/bin/env python3
"""Rewrite zone-nvidiagpu local_tags in config.yaml with the latest versions
published on https://www.nvidia.com/en-us/drivers/unix/.

Stdlib-only. Only the version digits in each of
the three matching lines change. If no new versions found, should not update the file.
Currently only supports amd64 drivers. A human must review the PR opened by the GH Action that runs this.
"""
import re
import sys
import urllib.request
from pathlib import Path

NVIDIA_URL = "https://www.nvidia.com/en-us/drivers/unix/"
CONFIG_PATH = Path("config.yaml")

# The three NVIDIA-page labels we care about, mapped to the literal text used
# in the trailing comment of each local_tags line in config.yaml. The script
# matches lines by the comment label, so the order in config.yaml is free.
LABELS = [
    "Latest Production Branch Version",
    "Latest New Feature Branch Version",
    "Latest Beta Version",
]

# Only match Linux x86_64 paragraph for now.
LINUX_X86_64_BLOCK = re.compile(
    r"<strong>Linux x86_64/AMD64/EM64T</strong>(?P<body>.*?)</p>",
    re.DOTALL,
)


def fetch_latest_versions(url: str = NVIDIA_URL) -> dict[str, str]:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req) as resp:
        html = resp.read().decode("utf-8", errors="replace")

    block_match = LINUX_X86_64_BLOCK.search(html)
    if not block_match:
        raise RuntimeError(
            "Could not locate the Linux x86_64 block on %s — page layout may have changed." % url
        )
    body = block_match.group("body")

    versions = {}
    for label in LABELS:
        # The page uses `<span calss="title">LABEL:</span> <a href="...">VERSION</a>`
        # (yes, "calss" — NVIDIA's typo). Match liberally on the label and the
        # next <a>...</a> so the parser survives small markup tweaks.
        pat = re.compile(
            re.escape(label) + r":\s*</span>\s*<a[^>]*>([0-9][0-9.]*[0-9])</a>",
            re.IGNORECASE,
        )
        m = pat.search(body)
        if not m:
            raise RuntimeError(
                "Could not find version for %r in Linux x86_64 block." % label
            )
        versions[label] = m.group(1)
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
            "config.yaml is missing local_tags lines for: %s" % ", ".join(sorted(missing))
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
