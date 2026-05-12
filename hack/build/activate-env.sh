#!/bin/sh

PREVIOUS_CWD="${PWD}"
REAL_SCRIPT="$(realpath "${0}")"
cd "$(dirname "${REAL_SCRIPT}")/../.." || return
unset REAL_SCRIPT

activate_env() {
	if ! type pipenv >/dev/null 2>&1; then
		pip3 install pipenv
	fi
	pipenv install --dev
	exec "$(pipenv activate)"
}

activate_env
unset -f activate_env
cd "${PREVIOUS_CWD}" || return
unset PREVIOUS_CWD
