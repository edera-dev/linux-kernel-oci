#!/usr/bin/env bash
# Publishes one review check's output into the single review the two checks
# share on a pull request.
#
# The two review workflows (pr-review-suggestions and pr-test-coverage) run
# independently, but a PR gets exactly one review from them, with a labeled
# section per check. This script owns that review. Given one check's output,
# it finds the review, replaces that check's section, keeps the other section
# as it was, and submits the result.
#
# The review event is fixed here as COMMENT and is not taken from the command
# line, so nothing run through this script can approve a pull request or
# request changes on one. It is the only write path the review workflows give
# the model.
#
# Both checks can finish at nearly the same time, so after writing this script
# waits briefly, reads the review back, and retries if its section is not
# there. If two first-time writes race and two reviews appear, the oldest one
# is canonical: the section is merged into it and the newer one this run
# created is emptied to a pointer, so later runs only ever see one.
#
# Each section records the head commit it was written against, and the body
# says so. The two checks run on their own schedules and either can be
# cancelled, so a section carried over from an earlier commit would otherwise
# read as a review of the current one. GitHub's own review commit_id cannot
# stand in for this: it is fixed when the review is created, while the body is
# edited in place on every later run.
#
# Usage:
#   post-pr-review.sh <owner/repo> <pr-number> <section> <body-file> <head-sha>
#                     [--only-if-unstamped]
#
#   section    pr-review-suggestions | pr-test-coverage
#   body-file  that check's output, no heading; the section heading is added
#   head-sha   the commit the check read, from
#              github.event.pull_request.head.sha. Not GITHUB_SHA, which on a
#              pull_request event is the ephemeral merge commit.
#
#   --only-if-unstamped  write nothing if the section already carries this
#              head. A check whose model run died before publishing uses this
#              to explain the gap without overwriting a review that did land.
#
# Prints the review id on success. Exits 2 on bad arguments and 1 when the
# section could not be published or did not read back.
set -euo pipefail

REVIEW_MARKER='<!-- pr-review -->'
STAMP_MARKER='<!-- stamp -->'
SECTIONS=(pr-review-suggestions pr-test-coverage)
PLACEHOLDER='_This check has not posted for this pull request yet._'
VERIFY_DELAY=${POST_PR_REVIEW_VERIFY_DELAY:-5}
ATTEMPTS=${POST_PR_REVIEW_ATTEMPTS:-3}
FELL_BACK=

usage='usage: post-pr-review.sh <owner/repo> <pr-number> <pr-review-suggestions|pr-test-coverage> <body-file> <head-sha> [--only-if-unstamped]'
REPO=${1:?$usage}
PR=${2:?$usage}
SECTION=${3:?$usage}
BODY=${4:?$usage}
HEAD_SHA=${5:?$usage}
ONLY_IF_UNSTAMPED=
case "${6:-}" in
  '') ;;
  --only-if-unstamped) ONLY_IF_UNSTAMPED=1 ;;
  *)
    echo "unknown option: $6" >&2
    exit 2
    ;;
esac

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
case "$SECTION" in
  pr-review-suggestions | pr-test-coverage) ;;
  *)
    echo "unknown section: $SECTION" >&2
    exit 2
    ;;
esac
if [ ! -s "$BODY" ]; then
  echo "body file is missing or empty: $BODY" >&2
  exit 2
fi
case "$HEAD_SHA" in
  *[!0-9a-f]* | '')
    echo "head sha must be hexadecimal: $HEAD_SHA" >&2
    exit 2
    ;;
esac
if grep -qF -- '<!-- section:' "$BODY" || grep -qF -- "$REVIEW_MARKER" "$BODY" \
  || grep -qF -- "$STAMP_MARKER" "$BODY"; then
  echo "body file must not contain section, review or stamp markers" >&2
  exit 2
fi

REVIEWS="repos/${REPO}/pulls/${PR}/reviews"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

label_for() {
  case "$1" in
    pr-review-suggestions) echo "PR Review" ;;
    pr-test-coverage) echo "Test Coverage" ;;
  esac
}

# Prints the lines between a section's open and close markers from stdin.
extract_section() {
  awk -v beg="<!-- section:$1 -->" -v fin="<!-- /section:$1 -->" '
    $0 == fin { inside = 0 }
    inside { print }
    $0 == beg { inside = 1 }
  '
}

# Prints the sha a carried-over section was written against, if it has one.
stamped_sha() {
  sed -n 's/^<!-- sha:\([0-9a-f]*\) -->$/\1/p' | head -1
}

# Prints a section's content without the stamp this script renders into it, so
# carrying a section over does not accumulate one stamp per run.
strip_stamp() {
  awk -v fin="<!-- /stamp -->" '
    skip { if ($0 == fin) { skip = 0; eat = 1 } next }
    eat { eat = 0; if ($0 == "") next }
    /^<!-- sha:[0-9a-f]* -->$/ { next }
    $0 == "<!-- stamp -->" { skip = 1; next }
    { print }
  '
}

# Prints the whole review body: this run's section from its body file, every
# other section carried over from the existing body, or a placeholder. Each
# section carries the head it was written against, so one carried over from an
# earlier commit is not read as a review of this one.
compose() {
  local existing=$1 name label content sha
  printf '%s\n' "$REVIEW_MARKER"
  for name in "${SECTIONS[@]}"; do
    label=$(label_for "$name")
    printf '\n## %s\n<!-- section:%s -->\n' "$label" "$name"
    if [ "$name" = "$SECTION" ]; then
      sha=$HEAD_SHA
      content=$(cat "$BODY")
    else
      content=$(extract_section "$name" <"$existing")
      sha=$(printf '%s\n' "$content" | stamped_sha)
      content=$(printf '%s\n' "$content" | strip_stamp)
      if [ -z "${content//[[:space:]]/}" ]; then
        content=$PLACEHOLDER
        sha=
      fi
    fi
    if [ -n "$sha" ]; then
      printf '<!-- sha:%s -->\n%s\n' "$sha" "$STAMP_MARKER"
      # shellcheck disable=SC2016  # markdown backticks, not expansion
      if [ "$sha" = "$HEAD_SHA" ]; then
        printf '_Reviewed at `%s`._\n' "${sha:0:7}"
      else
        printf '_Written against non-current tip `%s`, STALE. Rechecking._\n' "${sha:0:7}"
      fi
      printf '<!-- /stamp -->\n\n'
    fi
    printf '%s\n<!-- /section:%s -->\n' "$content" "$name"
  done
}

# Ids of bot reviews carrying the review marker, oldest first, one per line.
list_reviews() {
  gh api --paginate "$REVIEWS" \
    | jq -rs --arg m "$REVIEW_MARKER" \
      '[add[] | select(.user.type == "Bot" and ((.body // "") | contains($m)))] | sort_by(.id) | .[].id'
}

read_body() {
  gh api "${REVIEWS}/$1" --jq '.body // ""' | tr -d '\r'
}

submit_new() {
  gh api -X POST "$REVIEWS" -f event=COMMENT -F body=@"$1" --jq .id
}

# --only-if-unstamped callers are explaining an absence, not reviewing, so a
# section the check itself already published for this head wins.
if [ -n "$ONLY_IF_UNSTAMPED" ]; then
  existing=$(list_reviews | head -n 1)
  if [ -n "$existing" ] \
    && [ "$(read_body "$existing" | extract_section "$SECTION" | stamped_sha)" = "$HEAD_SHA" ]; then
    echo "section ${SECTION} is already published for ${HEAD_SHA:0:7}; leaving it" >&2
    echo "$existing"
    exit 0
  fi
fi

WANT=$(cat "$BODY")
CREATED=''
attempt=0
while :; do
  attempt=$((attempt + 1))
  id=$(list_reviews | head -n 1)
  if [ -z "$id" ]; then
    compose /dev/null >"$TMP/body.md"
    CREATED=$(submit_new "$TMP/body.md")
    id=$CREATED
  else
    read_body "$id" >"$TMP/existing.md"
    compose "$TMP/existing.md" >"$TMP/body.md"
    if ! gh api -X PUT "${REVIEWS}/${id}" -F body=@"$TMP/body.md" --jq .id >/dev/null; then
      echo "could not update review ${id}; submitting a new one." \
        "That review still carries the marker, so a later run will land here" \
        "again until someone removes or replaces it." >&2
      CREATED=$(submit_new "$TMP/body.md")
      id=$CREATED
      FELL_BACK=1
    fi
  fi

  # Let a concurrent writer land, then check the canonical review still
  # carries this section exactly as written.
  sleep "$VERIFY_DELAY"
  canonical=$(list_reviews | head -n 1)
  canonical=${canonical:-$id}
  # A review that could not be written is not a usable canonical: comparing
  # against it would never match, so the loop would submit a new review on
  # every attempt and still exit 1. The one this run created holds the merged
  # body, so verify against that.
  if [ -n "${FELL_BACK:-}" ]; then
    canonical=$id
  fi
  # Compared without the stamp, which this script renders rather than the check.
  if [ "$(read_body "$canonical" | extract_section "$SECTION" | strip_stamp)" = "$WANT" ]; then
    break
  fi
  if [ "$attempt" -ge "$ATTEMPTS" ]; then
    echo "section ${SECTION} did not read back from review ${canonical} after ${attempt} attempts" >&2
    exit 1
  fi
  echo "section ${SECTION} not in review ${canonical} yet; retrying" >&2
done

# A first-time write that lost a race left a second review behind. Only the
# one this run created is touched, and it loses the marker so it is never
# picked up again.
if [ -n "$CREATED" ] && [ "$CREATED" != "$canonical" ]; then
  printf '_Merged into the review above._\n' >"$TMP/superseded.md"
  gh api -X PUT "${REVIEWS}/${CREATED}" -F body=@"$TMP/superseded.md" --jq .id >/dev/null || true
fi

echo "$canonical"
