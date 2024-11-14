#!/bin/sh
set -e

cd "$(dirname "${0}")/../.."

./hack/build/generate-matrix.sh "${1}"
./hack/build/generate-docker-script.sh "matrix.json"
./docker.sh
