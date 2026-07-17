#!/usr/bin/env python3
"""Record an image digest emitted by `docker buildx build --metadata-file`.

Reads the buildx metadata JSON, extracts containerimage.digest, and appends an
entry {<image-name>: <digest>} to the cumulative digests file for this build.
The merge job consumes this file (one per (version, flavor, arch)) to create the
final manifest list with `docker buildx imagetools create`.
"""

import json
import os
import sys


def main():
    if len(sys.argv) != 4:
        print(
            "Usage: record-digest.py <image-name> <metadata-json> <digests-json>",
            file=sys.stderr,
        )
        sys.exit(1)

    image_name = sys.argv[1]
    metadata_path = sys.argv[2]
    digests_path = sys.argv[3]

    with open(metadata_path) as f:
        metadata = json.load(f)

    digest = metadata.get("containerimage.digest")
    if not digest:
        print(
            "ERROR: %s missing containerimage.digest key" % metadata_path,
            file=sys.stderr,
        )
        sys.exit(1)

    existing = {}
    if os.path.exists(digests_path):
        with open(digests_path) as f:
            existing = json.load(f)
    existing[image_name] = digest
    with open(digests_path, "w") as f:
        json.dump(existing, f, indent=2, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    main()
