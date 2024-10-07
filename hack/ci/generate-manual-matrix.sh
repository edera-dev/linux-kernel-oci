#!/bin/sh
set -e

rm -f "target/matrix.json"
python3 "$(dirname "${0}")/generate-manual-matrix.py" "target/matrix.json"
