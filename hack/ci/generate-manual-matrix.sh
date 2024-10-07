#!/bin/sh
set -e

cd "$(dirname "${0}")/../.."

mkdir -p target
rm -f "target/matrix.json"
python3 "$(dirname "${0}")/generate-manual-matrix.py" "target/matrix.json"
