#!/bin/sh
set -e

cd "$(dirname "${0}")/../.."

python3 "$(dirname "${0}")/generate-docker-script.py" "${@}"
