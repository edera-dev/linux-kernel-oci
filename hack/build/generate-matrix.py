import json
import sys

import matrix
from util import get_branch_tag_suffix, parse_text_constraint

# A build spec is "<type>" or "<type>:<constraints>", where constraints are
# semicolon-separated key=value pairs over `branch`, `flavor` and `arch`
# (e.g. "rebuild:branch=mainline;flavor=zone,host").
#
#   new      - build only what the registry does not already have. Because every
#              build carries an immutable <version>-g<commit> tag, this means
#              "build each branch that has moved since it was last built".
#   rebuild  - build everything the config selects, published or not. Use this
#              when something other than the kernel source changed: a kconfig
#              fragment, the buildenv, the packaging.
DEFAULT_BUILD_SPEC = "new"

BUILD_SPEC_TYPES = ["new", "rebuild"]

if len(sys.argv) > 1:
    build_spec = sys.argv[1]
else:
    build_spec = DEFAULT_BUILD_SPEC

if len(build_spec) == 0:
    build_spec = DEFAULT_BUILD_SPEC

build_spec_type = build_spec.split(":", maxsplit=1)[0]
if ":" in build_spec:
    build_spec_data = build_spec.split(":", maxsplit=1)[1]
else:
    build_spec_data = ""

if build_spec_type not in BUILD_SPEC_TYPES:
    raise Exception(
        "unknown build spec type: %s (expected one of %s)"
        % (build_spec_type, ", ".join(BUILD_SPEC_TYPES))
    )

final_matrix = matrix.generate_full_matrix()

# Builds from a branch of *this* repo (not of the kernel tree) publish under
# suffixed tags so they cannot overwrite the canonical ones. Applied before the
# `new` filter so that filter asks the registry about the tags this run would
# actually push, rather than about the canonical ones it will never touch.
branch_suffix = get_branch_tag_suffix()
if branch_suffix:
    for build in final_matrix:
        build["tags"] = ["%s-%s" % (t, branch_suffix) for t in build["tags"]]
        build["produces"] = ["%s-%s" % (p, branch_suffix) for p in build["produces"]]

if len(build_spec_data) > 0:
    # Filter before consulting the registry so `new` only spends crane calls on
    # the images the spec actually asked about.
    final_matrix = matrix.filter_matrix(
        final_matrix, parse_text_constraint(build_spec_data)
    )

if build_spec_type == "new":
    final_matrix = matrix.filter_new_builds(final_matrix)

matrix.validate_produce_conflicts(final_matrix)
matrix.fill_runners(final_matrix)
matrix.sort_matrix(final_matrix)

merges = matrix.generate_merges(final_matrix)

print("generated %s builds, %s merges" % (len(final_matrix), len(merges)))
matrix.summarize_matrix(final_matrix)

with open("matrix.json", "w") as mf:
    json.dump({"builds": final_matrix, "merges": merges}, mf)
    mf.write("\n")
