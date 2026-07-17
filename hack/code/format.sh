#!/bin/sh
set -e

REAL_SCRIPT="$(realpath "${0}")"
cd "$(dirname "${REAL_SCRIPT}")/../.."

# --check reports diffs and exits non-zero without writing; used to gate CI.
CHECK=""
if [ "${1:-}" = "--check" ]; then
	CHECK="1"
fi

# find, not a `**` glob: POSIX sh does not recurse `**`, so a glob would
# silently miss nested files and let unformatted code slip through the gate.
SH_FILES="$(find hack -type f -name '*.sh')"
PY_FILES="$(find hack -type f -name '*.py')"

if [ -n "${CHECK}" ]; then
	# Run both so a contributor sees every offending file in one pass,
	# rather than fixing shfmt only to trip black on the next run.
	RC=0
	# shellcheck disable=SC2086 # word-splitting the file list is intended
	shfmt -d ${SH_FILES} || RC=1
	# shellcheck disable=SC2086
	black --check ${PY_FILES} || RC=1
	exit "${RC}"
else
	# shellcheck disable=SC2086
	shfmt -w ${SH_FILES}
	# shellcheck disable=SC2086
	black ${PY_FILES}
fi
