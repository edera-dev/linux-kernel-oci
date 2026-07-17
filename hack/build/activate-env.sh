#!/bin/sh

PREVIOUS_CWD="${PWD}"
REAL_SCRIPT="$(realpath "${0}")"
cd "$(dirname "${REAL_SCRIPT}")/../.." || return
unset REAL_SCRIPT

activate_env() {
	if [ ! -d "venv" ]; then
		python3 -m venv venv
		pip install --upgrade pip
	fi
	# shellcheck source=/dev/null # venv is created at runtime, not present at lint time
	. venv/bin/activate
	pip3 install -qq -r requirements.txt
}

activate_env
unset -f activate_env
cd "${PREVIOUS_CWD}" || return
unset PREVIOUS_CWD
