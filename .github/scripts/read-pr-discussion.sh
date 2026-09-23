#!/usr/bin/env bash
# Prints the discussion on a pull request for the review checks to read.
#
# The review workflows let the model run this script and nothing else that
# reaches the API. An allowlist entry naming an endpoint cannot make the call
# read-only: `gh api` takes the last `--method` on its command line, so
# `gh api -X GET <endpoint> -X POST -f body=...` still matches a `-X GET`
# prefix and still writes. Fixing the command here is what keeps these reads
# read-only.
#
# Usage: read-pr-discussion.sh <owner/repo> <pr-number>
set -euo pipefail

usage='usage: read-pr-discussion.sh <owner/repo> <pr-number>'
REPO=${1:?$usage}
PR=${2:?$usage}
if [ "$#" -gt 2 ]; then
  echo "unexpected argument: $3" >&2
  exit 2
fi
case "$REPO" in
  */*) ;;
  *)
    echo "repository must be owner/repo: $REPO" >&2
    exit 2
    ;;
esac
case "$PR" in
  '' | *[!0-9]*)
    echo "pull request number must be numeric: $PR" >&2
    exit 2
    ;;
esac

echo '=== description, issue comments and review summaries ==='
gh pr view "$PR" --repo "$REPO" --json body,comments,reviews

echo '=== inline review comments ==='
gh api --method GET "repos/${REPO}/pulls/${PR}/comments" --jq '.[].body'
