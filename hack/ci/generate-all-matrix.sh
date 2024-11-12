#!/bin/sh
set -e

cd "$(dirname "${0}")/../.."

./hack/ci/generate-stable-matrix.sh
mv target/matrix.json target/stable-matrix.json
./hack/ci/generate-backbuild-matrix.sh
mv target/matrix.json target/backbuild-matrix.json
python3 hack/ci/merge-matrix.py target/stable-matrix.json target/backbuild-matrix.json >target/matrix.json
