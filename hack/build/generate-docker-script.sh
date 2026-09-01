#!/bin/sh
set -e

cd "$(dirname "${0}")/../.."

uv run "$(dirname "${0}")/generate-docker-script.py" "${@}"
