import json
import sys
import os

from matrix import generate_matrix

matrix_path = sys.argv[1]
tags = {}

kernel_versions = os.getenv("KERNEL_VERSIONS")
if kernel_versions is None or len(kernel_versions) == 0:
    print("KERNEL_VERSIONS must be specified", file=sys.stderr)
    exit(1)

kernel_versions = kernel_versions.split(",")

for kernel_version in kernel_versions:
    parts = kernel_version.split(":", 1)
    tag_list = []
    if len(parts) > 1:
        kernel_version = parts[0]
        tag_list = parts[1].split(",")
    tag_list.append(kernel_version)
    for tag in tag_list:
        tags[tag] = kernel_version

generate_matrix(matrix_path, tags)
