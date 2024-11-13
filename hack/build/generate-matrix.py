import json
import os

import matrix
from util import parse_text_constraint, maybe


def construct_stable_matrix():
    stable_matrix = matrix.generate_stable_matrix()
    return stable_matrix


def construct_backbuild_matrix():
    backbuild_matrix = matrix.generate_backbuild_matrix()
    return backbuild_matrix


def construct_all_matrix():
    stable_matrix = construct_stable_matrix()
    backbuild_matrix = construct_backbuild_matrix()
    all_matrix = matrix.merge_matrix([stable_matrix, backbuild_matrix])
    return all_matrix


def construct_manual_matrix(exact_versions):
    reflective = {}
    for version in exact_versions:
        reflective[version] = version
    return matrix.generate_matrix(reflective)


DEFAULT_BUILD_SPEC = "new"

build_spec = os.getenv("KERNEL_BUILD_SPEC", DEFAULT_BUILD_SPEC)
build_spec_type = build_spec.split(":", maxsplit=1)[0]
if ":" in build_spec:
    build_spec_data = build_spec.split(":", maxsplit=1)[1]
else:
    build_spec_data = ""

constraint = {}
if len(build_spec_data) > 0:
    constraint = parse_text_constraint(build_spec_data)

apply_config_versions = True

if build_spec_type == "new":
    first_matrix = matrix.filter_new_builds(construct_all_matrix())
elif build_spec_type == "rebuild":
    first_matrix = construct_all_matrix()
elif build_spec_type == "unsafe-all":
    first_matrix = construct_all_matrix()
    apply_config_versions = False
elif build_spec_type == "stable":
    first_matrix = construct_stable_matrix()
elif build_spec_type == "override":
    first_matrix = construct_all_matrix()
    apply_config_versions = False
elif build_spec_type == "manual":
    versions = maybe(constraint, "exact")
    if versions is None:
        versions = []
    first_matrix = construct_manual_matrix(versions)
    apply_config_versions = False
else:
    raise Exception("unknown build spec type: %s" % build_spec_type)

if apply_config_versions:
    final_matrix = matrix.filter_config_versions(first_matrix)
else:
    final_matrix = first_matrix

if len(build_spec_data) > 0:
    constraint = parse_text_constraint(build_spec_data)
    final_matrix = matrix.filter_matrix(final_matrix, constraint)

matrix.validate_produce_conflicts(final_matrix)

print("generated %s builds" % len(final_matrix["builds"]))
matrix.summarize_matrix(final_matrix)

with open("matrix.json", "w") as f:
    json.dump(final_matrix, f)
    f.write("\n")
