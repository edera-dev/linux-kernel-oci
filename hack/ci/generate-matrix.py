import sys
import json
from packaging.version import Version

data_path = sys.argv[1]
matrix_path = sys.argv[2]

all_versions = open('%s/all-versions' % data_path, 'r').read().strip().splitlines()
release_info = json.loads(open('%s/releases.json' % data_path, 'r').read())
latest_stable = release_info['latest_stable']['version']

def version_parts(version: str) -> (int, int, int):
  parts = version.split('.')
  if len(parts) == 1:
    return (int(parts[0]), 0, 0)
  elif len(parts) == 2:
    return (int(parts[0]), int(parts[1]), 0)
  elif len(parts) == 3:
    return (int(parts[0]), int(parts[1]), int(parts[2]))
  else:
    raise Exception("invalid version %s" % version
)

def version_greater(left: (int, int, int), right: (int, int, int)) -> bool:
  if left[0] > right[0]:
    return True
  if left[1] > right[1]:
    return True
  if left[2] > right[2]:
    return True
  return False

tags = {}
major_minors = {}

for version in all_versions:
  parts = version_parts(version)

  if parts[0] < 5:
    continue

  if version == latest_stable:
    tags['stable'] = version
  major = str(parts[0])
  major_minor = "%s.%s" % (parts[0], parts[1])

  if major in tags:
    existing = tags[major]
    if version_greater(parts, version_parts(existing)):
      tags[major] = version
  else:
    tags[major] = version

  if major_minor in tags:
    existing = tags[major_minor]
    if version_greater(parts, version_parts(existing)):
      tags[major_minor] = version
      major_minors[major_minor] = version
  else:
    tags[major_minor] = version
    major_minors[major_minor] = version

tags["latest"] = tags["stable"]

for tag in list(tags.keys()):
  version = tags[tag]
  tags[version] = version

unique_versions = list(set(tags.values()))
unique_versions.sort(key=Version)

version_builds = []

for version in unique_versions:
  version_tags = []
  for tag in tags:
    tag_version = tags[tag]
    if tag_version == version:
      version_tags.append(tag)
  parts = version_parts(version)
  src_url = "https://cdn.kernel.org/pub/linux/kernel/v%s.x/linux-%s.tar.xz" % (parts[0], version)
  version_builds.append({
    "version": version,
    "tags": version_tags,
    "source": src_url,
  })

matrix = {
  "arch": ["x86_64", "aarch64"],
  "builds": version_builds,
}

matrix_file = open(matrix_path, 'w')
matrix_file.write(json.dumps(matrix) + "\n")
