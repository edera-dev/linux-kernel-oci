#!/usr/bin/env python3
"""Generate merge.sh for one (version, flavor) merge entry.

The CI build matrix produces per-arch images pushed to the registry by digest
only (no tags). This script consumes the digest artifacts produced by those
per-arch jobs and emits a shell script that:

  1. Runs `docker buildx imagetools create` once per produced image, attaching
     all per-arch digests under the desired tags. This is what stitches the
     single-platform pushes into the published multi-arch manifest list.
  2. Signs each published tag with cosign.

Env vars consumed:
  KERNEL_PUBLISH   "true" to actually run; otherwise the script no-ops.
  KERNEL_PRODUCES  Comma-separated image:tag list (from the merge matrix entry).
  DIGESTS_DIR      Directory containing downloaded artifact subdirs, each with
                   a digests.json. Defaults to "digests".

The merge matrix entry already contains the canonical produces list and tags,
so we don't need to re-derive them here.
"""

import json
import os
import stat
import sys
from collections import OrderedDict

from util import parse_text_bool, smart_script_split


def quoted(text: str) -> str:
    return '"%s"' % text


def collect_digests(digests_dir: str) -> dict[str, list[str]]:
    """Walk digests_dir for all digests.json files and union them.

    Returns {image_name: [digest, digest, ...]} with one digest per arch.
    """
    image_digests: dict[str, list[str]] = OrderedDict()
    if not os.path.isdir(digests_dir):
        return image_digests
    for root, _, files in os.walk(digests_dir):
        for fname in files:
            if fname != "digests.json":
                continue
            with open(os.path.join(root, fname)) as f:
                data = json.load(f)
            for image_name, digest in data.items():
                bucket = image_digests.setdefault(image_name, [])
                if digest not in bucket:
                    bucket.append(digest)
    return image_digests


def main() -> None:
    publish = parse_text_bool(os.getenv("KERNEL_PUBLISH", "false"))
    digests_dir = os.getenv("DIGESTS_DIR", "digests")
    produces_env = os.getenv("KERNEL_PRODUCES", "")

    lines = ["#!/bin/sh", "set -e"]

    if not publish:
        lines += [
            'echo "merge: KERNEL_PUBLISH is not true; nothing to merge."',
            "exit 0",
        ]
    elif not produces_env:
        print("ERROR: KERNEL_PRODUCES not set", file=sys.stderr)
        sys.exit(1)
    else:
        produce_list = [p for p in produces_env.split(",") if p]
        image_to_tags: dict[str, list[str]] = OrderedDict()
        for produce in produce_list:
            image_name, tag = produce.rsplit(":", 1)
            image_to_tags.setdefault(image_name, []).append(tag)

        image_digests = collect_digests(digests_dir)
        for image_name, tags in image_to_tags.items():
            digests = image_digests.get(image_name)
            if not digests:
                print(
                    "ERROR: no digests found for %s under %s"
                    % (image_name, digests_dir),
                    file=sys.stderr,
                )
                sys.exit(1)

            create_command = ["docker", "buildx", "imagetools", "create"]
            for tag in tags:
                create_command += ["-t", quoted("%s:%s" % (image_name, tag))]
            for digest in digests:
                create_command += [quoted("%s@%s" % (image_name, digest))]
            lines += [""]
            lines += smart_script_split(
                create_command,
                "stage=merge image=%s archs=%d" % (image_name, len(digests)),
            )

            for tag in tags:
                ref = "%s:%s" % (image_name, tag)
                sign_command = ["cosign", "sign", "--yes", quoted(ref)]
                lines += [""]
                lines += smart_script_split(sign_command, "stage=sign image=%s" % ref)

    with open("merge.sh", "w") as out:
        out.write("\n".join(lines))
        out.write("\n")
    s = os.stat("merge.sh")
    os.chmod("merge.sh", s.st_mode | stat.S_IEXEC)


if __name__ == "__main__":
    main()
