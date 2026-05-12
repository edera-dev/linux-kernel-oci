#!/bin/sh
set -e

go install github.com/google/go-containerregistry/cmd/crane@v0.20.2

if ! type pipenv >/dev/null 2>&1; then
	pip3 install pipenv
fi
pipenv install --system
