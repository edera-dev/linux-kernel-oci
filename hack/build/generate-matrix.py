import json

import matrix

stable_matrix = matrix.generate_stable_matrix()
backbuild_matrix = matrix.generate_backbuild_matrix()
all_matrix = matrix.merge_matrix([stable_matrix, backbuild_matrix])
only_new_matrix = matrix.filter_new_builds(all_matrix)
final_matrix = matrix.generate_final_matrix(only_new_matrix)

with open("matrix.json", "w") as f:
    json.dump(final_matrix, f, indent=2)
    f.write("\n")
