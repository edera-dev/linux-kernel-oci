#!/bin/sh

PREVIOUS_CWD="${PWD}"
REAL_SCRIPT="$(realpath "${0}")"
cd "$(dirname "${REAL_SCRIPT}")/../.." || return
unset REAL_SCRIPT

activate_env() {
	if [ ! -d "venv" ]; then
		uv venv venv
	fi
	# shellcheck source=/dev/null # venv is created at runtime, not present at lint time
	. venv/bin/activate
	uv sync
}

activate_env
unset -f activate_env
cd "${PREVIOUS_CWD}" || return
unset PREVIOUS_CWD
