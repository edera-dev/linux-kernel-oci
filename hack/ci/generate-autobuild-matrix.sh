#!/bin/sh
set -e

cd "$(dirname "${0}")/../.."

if [ -z "${1}" ]; then
	echo "Usage: generate-autobuild-matrix.sh <image-name-format>" >&2
	exit 1
fi

./hack/ci/generate-all-matrix.sh
python3 hack/ci/annotate-produces.py target/matrix.json "${1}" >target/matrix-produces.json
if [ "${AUTOBUILD_FORCE_BUILD}" != "1" ]; then
	python3 hack/ci/only-new-builds.py target/matrix-produces.json >target/matrix-full.json
fi

python3 hack/ci/limit-gh-builds.py target/matrix-full.json >target/matrix.json
