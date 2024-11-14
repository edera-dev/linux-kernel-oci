#!/bin/sh
set -e

go install github.com/google/go-containerregistry/cmd/crane@v0.20.2
pip3 install -r requirements.txt
