#!/usr/bin/env bash
# Tests for .github/scripts/post-pr-review.sh and the two workflows that call it.
#
# Runs the publisher against a fake gh (tests/fake-gh/gh) that keeps review
# state on disk and logs every call, then checks the review that results. The
# static checks at the end read the two workflow files and assert the parts of
# them that must not drift: triggers, permissions, the fork gate, the
# allowlist, and the fact that the model step cannot turn a PR red.
#
# Run from anywhere: bash .github/scripts/tests/post-pr-review.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
SCRIPT="$ROOT/.github/scripts/post-pr-review.sh"
WORKFLOWS=("$ROOT/.github/workflows/pr-review-suggestions.yml" "$ROOT/.github/workflows/pr-test-coverage.yml")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cp "$HERE/fake-gh/gh" "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export POST_PR_REVIEW_VERIFY_DELAY=0
export POST_PR_REVIEW_ATTEMPTS=3

failures=0
pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1" >&2
  failures=$((failures + 1))
}
check() {
  # check <description> <command...>; the command's exit status is the verdict.
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

reset_state() {
  export FAKE_GH_STATE="$WORK/state"
  rm -rf "$FAKE_GH_STATE"
  mkdir -p "$FAKE_GH_STATE/reviews"
  unset FAKE_GH_AFTER_LIST_HOOK FAKE_GH_PUT_FAIL_IDS FAKE_GH_USER_TYPE FAKE_GH_USER_LOGIN
}
HEAD_SHA=${HEAD_SHA:-0b404d216667aa1ca9d1cbbbb0a3f95d3b3ba7d2}
publish() {
  # publish <section> <text...>; writes the text to a body file and runs the
  # script against $HEAD_SHA, which a case may set to move the head.
  local section=$1
  shift
  printf '%s\n' "$*" >"$WORK/body-$section.md"
  bash "$SCRIPT" edera-dev/linux-kernel-oci 42 "$section" "$WORK/body-$section.md" "$HEAD_SHA"
}
review_count() { find "$FAKE_GH_STATE/reviews" -name '*.json' | wc -l | tr -d ' '; }
marked_count() {
  grep -l 'pr-review' "$FAKE_GH_STATE"/reviews/*.json 2>/dev/null | wc -l | tr -d ' '
}
body_of() { jq -r .body "$FAKE_GH_STATE/reviews/$1.json"; }
state_of() { jq -r .state "$FAKE_GH_STATE/reviews/$1.json"; }
calls() { cat "$FAKE_GH_STATE/calls.log"; }
count_calls() { grep -c -- "$1" "$FAKE_GH_STATE/calls.log" || true; }
section_of() {
  # section_of <id> <section>: the lines inside that section of the review body.
  body_of "$1" | awk -v beg="<!-- section:$2 -->" -v fin="<!-- /section:$2 -->" '
    $0 == fin { inside = 0 }
    inside { print }
    $0 == beg { inside = 1 }
  '
}
no_comment_calls() {
  # The fake fails any non-review endpoint, but the log is the proof.
  ! grep -q -E 'issues/[0-9]+/comments|pulls/[0-9]+/comments|pr comment|issues/comments' "$FAKE_GH_STATE/calls.log"
}
only_comment_events() {
  ! grep -q -E 'event=(APPROVE|REQUEST_CHANGES)' "$FAKE_GH_STATE/calls.log" \
    && [ "$(grep -c 'event=COMMENT' "$FAKE_GH_STATE/calls.log")" -ge 1 ]
}

echo "# first publish creates exactly one comment review with both sections"
reset_state
id=$(publish pr-review-suggestions "I went through this. Nothing concerning.")
check "exit 0 and prints an id" test -n "$id"
check "exactly one review exists" test "$(review_count)" = 1
check "review is COMMENTED" test "$(state_of "$id")" = COMMENTED
check "one POST with event=COMMENT" test "$(count_calls 'event=COMMENT')" = 1
check "PR Review heading present" grep -q '^## PR Review$' <(body_of "$id")
check "Test Coverage heading present" grep -q '^## Test Coverage$' <(body_of "$id")
check "PR Review section holds the output" grep -q 'Nothing concerning' <(section_of "$id" pr-review-suggestions)
check "Test Coverage section holds the placeholder" grep -q 'has not posted' <(section_of "$id" pr-test-coverage)
check "no standalone comment endpoint called" no_comment_calls
check "no blocking event ever sent" only_comment_events

echo "# the other check publishes into the same review"
id2=$(publish pr-test-coverage "Testing looks right for this.")
check "same review id" test "$id2" = "$id"
check "still exactly one review" test "$(review_count)" = 1
check "no second POST" test "$(count_calls 'event=COMMENT')" = 1
check "updated with PUT" test "$(count_calls '-X PUT')" -ge 1
check "PR Review section kept" grep -q 'Nothing concerning' <(section_of "$id" pr-review-suggestions)
check "Test Coverage section filled" grep -q 'Testing looks right' <(section_of "$id" pr-test-coverage)
check "placeholder gone" bash -c "! grep -q 'has not posted' <(jq -r .body '$FAKE_GH_STATE/reviews/$id.json')"
check "still no standalone comment endpoint called" no_comment_calls

echo "# rerun for the same head replaces a section instead of adding a review"
id3=$(publish pr-review-suggestions "One thing to fix before merge." "**Serious: the new input reaches a shell unquoted.**" "The value is interpolated into the run block, so it is parsed by bash before the script sees it.")
check "same review id" test "$id3" = "$id"
check "still exactly one review" test "$(review_count)" = 1
check "still one POST in total" test "$(count_calls 'event=COMMENT')" = 1
check "PR Review section replaced" grep -q 'One thing to fix before merge' <(section_of "$id" pr-review-suggestions)
check "old PR Review text gone" bash -c "! grep -q 'Nothing concerning' <(jq -r .body '$FAKE_GH_STATE/reviews/$id.json')"
check "Test Coverage section untouched" grep -q 'Testing looks right' <(section_of "$id" pr-test-coverage)
check "serious finding still leaves the review COMMENTED" test "$(state_of "$id")" = COMMENTED
check "no blocking event ever sent" only_comment_events
check "exactly one review carries the marker" test "$(marked_count)" = 1

echo "# a human review that pastes the marker is not touched"
reset_state
FAKE_GH_USER_TYPE=User FAKE_GH_USER_LOGIN=someone gh api -X POST repos/edera-dev/linux-kernel-oci/pulls/42/reviews -f event=COMMENT -f body='<!-- pr-review --> mine' >/dev/null
human=$(jq -r .id "$FAKE_GH_STATE"/reviews/*.json)
id=$(publish pr-test-coverage "Nothing here needs a test.")
check "a separate bot review was created" test "$id" != "$human"
check "human review body unchanged" test "$(body_of "$human")" = '<!-- pr-review --> mine'
check "bot review holds the section" grep -q 'Nothing here needs a test' <(section_of "$id" pr-test-coverage)

echo "# a section carried over from an older commit says so"
reset_state
old_sha=0b404d216667aa1ca9d1cbbbb0a3f95d3b3ba7d2
new_sha=57e5519357ac4e0f0a1a6c6bb7d2d0c4bb6b1f3e
HEAD_SHA=$old_sha publish pr-review-suggestions "Serious: something is wrong." >/dev/null
id=$(HEAD_SHA=$new_sha publish pr-test-coverage "Coverage read at the new head.")
check "this run's section is marked current" \
  grep -qF "_Reviewed at \`${new_sha:0:7}\`._" <(section_of "$id" pr-test-coverage)
check "the carried-over section names the commit it was written against" \
  grep -qF "\`${old_sha:0:7}\`" <(section_of "$id" pr-review-suggestions)
check "the carried-over section is marked stale" \
  grep -q 'STALE' <(section_of "$id" pr-review-suggestions)
check "the carried-over findings are kept" \
  grep -q 'something is wrong' <(section_of "$id" pr-review-suggestions)

echo "# re-running a section at the new head clears its staleness"
id=$(HEAD_SHA=$new_sha publish pr-review-suggestions "Serious: still wrong at the new head.")
check "no longer marked stale" \
  bash -c '! grep -q "STALE" <(section_of "'"$id"'" pr-review-suggestions)'
check "marked current instead" \
  grep -qF "_Reviewed at \`${new_sha:0:7}\`._" <(section_of "$id" pr-review-suggestions)

echo "# stamps do not accumulate across runs"
check "one stamp per section" \
  test "$(body_of "$id" | grep -c '^<!-- stamp -->$')" = 2

echo "# a check that did not finish says so without overwriting a review"
reset_state
printf '%s\n' "This check did not finish." >"$WORK/unfinished.md"
id=$(publish pr-review-suggestions "Serious: something is wrong.")
same=$(bash "$SCRIPT" edera-dev/linux-kernel-oci 42 pr-review-suggestions "$WORK/unfinished.md" "$HEAD_SHA" --only-if-unstamped 2>/dev/null)
check "exits 0 and names the review" test "$same" = "$id"
check "the review of this head is kept" grep -q 'something is wrong' <(section_of "$id" pr-review-suggestions)
check "the note did not land" bash -c "! grep -q 'did not finish' <(jq -r .body '$FAKE_GH_STATE/reviews/$id.json')"
check "the review was not rewritten" test "$(count_calls '-X PUT')" = 0

echo "# the note fills a section that never posted"
reset_state
id=$(publish pr-test-coverage "Coverage read at this head.")
bash "$SCRIPT" edera-dev/linux-kernel-oci 42 pr-review-suggestions "$WORK/unfinished.md" "$HEAD_SHA" --only-if-unstamped >/dev/null
check "the placeholder is replaced by the note" grep -q 'did not finish' <(section_of "$id" pr-review-suggestions)
check "the other section is untouched" grep -q 'Coverage read at this head' <(section_of "$id" pr-test-coverage)

echo "# the note replaces a section left behind at an older head"
reset_state
newer=57e5519357ac4e0f0a1a6c6bb7d2d0c4bb6b1f3e
HEAD_SHA=0b404d216667aa1ca9d1cbbbb0a3f95d3b3ba7d2 publish pr-review-suggestions "Serious: something is wrong." >/dev/null
id=$(bash "$SCRIPT" edera-dev/linux-kernel-oci 42 pr-review-suggestions "$WORK/unfinished.md" "$newer" --only-if-unstamped)
check "the stale review is replaced" bash -c "! grep -q 'something is wrong' <(jq -r .body '$FAKE_GH_STATE/reviews/$id.json')"
check "the note is stamped at the current head" \
  grep -qF "_Reviewed at \`${newer:0:7}\`._" <(section_of "$id" pr-review-suggestions)
check "an unknown option is rejected" \
  bash -c "! bash '$SCRIPT' edera-dev/linux-kernel-oci 42 pr-review-suggestions '$WORK/unfinished.md' '$newer' --nope 2>/dev/null"

echo "# the head sha is required and must be a sha"
reset_state
printf 'text\n' >"$WORK/body-args.md"
check "missing head sha is rejected" \
  bash -c '! bash "'"$SCRIPT"'" edera-dev/linux-kernel-oci 42 pr-review-suggestions "'"$WORK"'/body-args.md"'
check "non-hex head sha is rejected" \
  bash -c '! bash "'"$SCRIPT"'" edera-dev/linux-kernel-oci 42 pr-review-suggestions "'"$WORK"'/body-args.md" not-a-sha'

echo "# concurrent writer between the listing and the write is merged, not lost"
reset_state
first=$(publish pr-review-suggestions "PR review text.")
export FAKE_GH_AFTER_LIST_HOOK="jq --arg b \"\$(printf '<!-- pr-review -->\n\n## PR Review\n<!-- section:pr-review-suggestions -->\nPR review text, updated by the other run.\n<!-- /section:pr-review-suggestions -->\n\n## Test Coverage\n<!-- section:pr-test-coverage -->\n_This check has not posted for this pull request yet._\n<!-- /section:pr-test-coverage -->')\" '.body = \$b' '$FAKE_GH_STATE/reviews/$first.json' > '$FAKE_GH_STATE/reviews/tmp' && mv '$FAKE_GH_STATE/reviews/tmp' '$FAKE_GH_STATE/reviews/$first.json'"
id=$(publish pr-test-coverage "Coverage text.")
unset FAKE_GH_AFTER_LIST_HOOK
check "same review" test "$id" = "$first"
check "still exactly one review" test "$(review_count)" = 1
check "this run's section landed" grep -q 'Coverage text' <(section_of "$id" pr-test-coverage)
check "the other run's newer section survived" grep -q 'updated by the other run' <(section_of "$id" pr-review-suggestions)

echo "# two first-time writers racing converge on the oldest review"
reset_state
export FAKE_GH_AFTER_LIST_HOOK="printf '%s\n' '<!-- pr-review -->' '' '## PR Review' '<!-- section:pr-review-suggestions -->' 'Other check got there first.' '<!-- /section:pr-review-suggestions -->' '' '## Test Coverage' '<!-- section:pr-test-coverage -->' '_This check has not posted for this pull request yet._' '<!-- /section:pr-test-coverage -->' > '$WORK/other.md' && gh api -X POST repos/edera-dev/linux-kernel-oci/pulls/42/reviews -f event=COMMENT -F body=@'$WORK/other.md' >/dev/null"
id=$(publish pr-test-coverage "Coverage text.")
unset FAKE_GH_AFTER_LIST_HOOK
oldest=$(jq -rs 'sort_by(.id) | .[0].id' "$FAKE_GH_STATE"/reviews/*.json)
newest=$(jq -rs 'sort_by(.id) | .[-1].id' "$FAKE_GH_STATE"/reviews/*.json)
check "canonical is the oldest review" test "$id" = "$oldest"
check "canonical holds both sections" bash -c "grep -q 'Other check got there first' <(jq -r .body '$FAKE_GH_STATE/reviews/$oldest.json') && grep -q 'Coverage text' <(jq -r .body '$FAKE_GH_STATE/reviews/$oldest.json')"
check "only one review still carries the marker" test "$(marked_count)" = 1
check "the losing review points at the canonical one" grep -q 'Merged into the review above' <(body_of "$newest")
check "no blocking event ever sent" only_comment_events

echo "# a review that cannot be updated falls back to a new comment review"
reset_state
first=$(publish pr-review-suggestions "PR review text.")
# shellcheck disable=SC2034  # read from the environment by tests/fake-gh/gh.
FAKE_GH_PUT_FAIL_IDS="$first" id=$(publish pr-test-coverage "Coverage text." 2>/dev/null)
check "publish still succeeds" test -n "$id"
check "new review is COMMENTED" test "$(state_of "$id")" = COMMENTED
check "no blocking event ever sent" only_comment_events

echo "# bad input never reaches gh"
reset_state
check "unknown section rejected" bash -c "! bash '$SCRIPT' edera-dev/linux-kernel-oci 42 nope '$WORK/body-pr-test-coverage.md' 2>/dev/null"
check "non-numeric pr rejected" bash -c "! bash '$SCRIPT' edera-dev/linux-kernel-oci abc pr-test-coverage '$WORK/body-pr-test-coverage.md' 2>/dev/null"
check "empty body rejected" bash -c "! bash '$SCRIPT' edera-dev/linux-kernel-oci 42 pr-test-coverage /dev/null 2>/dev/null"
printf '<!-- section:pr-test-coverage -->\nx\n' >"$WORK/marked.md"
check "body with markers rejected" bash -c "! bash '$SCRIPT' edera-dev/linux-kernel-oci 42 pr-test-coverage '$WORK/marked.md' 2>/dev/null"
check "no gh call was made" test ! -s "$FAKE_GH_STATE/calls.log"

echo "# the publisher itself"
check "COMMENT is the only review event in the script" test "$(grep -c 'event=' "$SCRIPT")" = 1
check "and it is COMMENT" grep -q 'event=COMMENT' "$SCRIPT"
check "script never approves or requests changes" bash -c "! grep -q -E 'APPROVE|REQUEST_CHANGES' '$SCRIPT'"
check "script never posts issue comments" bash -c "! grep -q -E 'issues/|pr comment' '$SCRIPT'"

echo "# the workflows keep their triggers, permissions, gate, and failure behavior"
for wf in "${WORKFLOWS[@]}"; do
  name=$(basename "$wf")
  check "$name: pull_request trigger with the same types" grep -q '^    types: \[opened, synchronize, ready_for_review\]$' "$wf"
  check "$name: same branches" grep -qF "    branches: [main]" "$wf"
  check "$name: no pull_request_target" bash -c "! grep -q 'pull_request_target' '$wf'"
  check "$name: no PAT or secret token" bash -c "! grep -q -E 'secrets\.[A-Z_]*(TOKEN|PAT)' '$wf'"
  check "$name: fork PRs skipped" grep -q 'github.event.pull_request.head.repo.full_name == github.repository' "$wf"
  check "$name: contents read" grep -q '^      contents: read$' "$wf"
  check "$name: pull-requests write" grep -q '^      pull-requests: write$' "$wf"
  check "$name: id-token write" grep -q '^      id-token: write$' "$wf"
  check "$name: no other permissions" test "$(grep -c -E '^      (contents|pull-requests|id-token|issues|actions|checks|statuses|packages|deployments|discussions|pages|repository-projects|security-events|attestations): ' "$wf")" = 3
  check "$name: model step is continue-on-error" grep -q '^        continue-on-error: true$' "$wf"
  check "$name: a run that fails before publishing explains itself in its section" \
    grep -q -- '--only-if-unstamped' "$wf"
  check "$name: and does that only when the model step failed" \
    grep -qE "if: steps\.[a-z]+\.outcome == 'failure'" "$wf"
  check "$name: the step that writes it cannot turn the PR red either" \
    test "$(grep -c '^        continue-on-error: true$' "$wf")" = 2
  # shellcheck disable=SC2016  # matching the literal shell in the workflow.
  check "$name: the summary tells a failed run from a declined one" \
    grep -qF 'if [ "$OUTCOME" = "failure" ]' "$wf"
  # shellcheck disable=SC2016  # matching the literal \${{ }} in the workflow.
  check "$name: publishes through the script" grep -q 'bash .github/scripts/post-pr-review.sh \${{ github.repository }} \${{ github.event.pull_request.number }}' "$wf"
  check "$name: allowlist has the script" grep -q 'Bash(bash .github/scripts/post-pr-review.sh:\*)' "$wf"
  check "$name: allowlist has no gh pr comment" bash -c "! grep -q 'gh pr comment' '$wf'"
  check "$name: allowlist has no gh pr review" bash -c "! grep -q 'gh pr review' '$wf'"
  check "$name: allowlist has no open gh api" bash -c "! grep -q 'Bash(gh api:\*)' '$wf'"
  check "$name: allowlist has no gh api write method" bash -c "! grep -q -E 'Bash\(gh api -X (PATCH|POST|PUT|DELETE)' '$wf'"
  check "$name: allowlist reaches no review endpoint" bash -c "! grep -q -E 'Bash\([^)]*/reviews' '$wf'"
  check "$name: never approves or requests changes" bash -c "! grep -q -E 'APPROVE|REQUEST_CHANGES|--approve|--request-changes' '$wf'"
  check "$name: prompt does not promise a footer the skills no longer emit" bash -c "! grep -q -E 'carries a footer|nothing here blocks the merge' '$wf'"
  check "$name: outcome is still reported from the action's conclusion" grep -q 'steps\.[a-z]*\.outputs\.conclusion' "$wf"
  check "$name: still says it never blocks a merge" grep -q 'This job never blocks a merge' "$wf"
done
# The skills name the old footer in their lists of phrases to avoid, so look
# for the footer as it would actually be emitted: an italic line on its own.
check "no skill emits a footer disclaimer" bash -c "! grep -rqE '^_[^_]*blocks the merge[^_]*_\$' '$ROOT/.review/skills'"

echo "# the publisher and the workflows agree on the section names"
for name in pr-review-suggestions pr-test-coverage; do
  check "publisher knows section $name" grep -q "^SECTIONS=(.*\b$name\b" "$SCRIPT"
  check "a workflow writes section $name" grep -q -- "post-pr-review.sh .* $name " "${WORKFLOWS[@]}"
done

check "pr-review-suggestions still follows its skill" grep -q '\.review/skills/pr-review/SKILL.md exactly' "${WORKFLOWS[0]}"
check "pr-test-coverage still follows its skill" grep -q '\.review/skills/test-coverage-review/SKILL.md exactly' "${WORKFLOWS[1]}"
check "pr-review-suggestions writes its own section" grep -q 'pr-review-suggestions /tmp/pr-review-body.md' "${WORKFLOWS[0]}"
check "pr-test-coverage writes its own section" grep -q 'pr-test-coverage /tmp/pr-test-coverage-body.md' "${WORKFLOWS[1]}"
# The head sha, not GITHUB_SHA, which on a pull_request event is the merge commit.
for workflow in "${WORKFLOWS[@]}"; do
  check "$(basename "$workflow") passes the head sha to the publisher" \
    grep -q 'post-pr-review.sh .*head\.sha }}$' "$workflow"
done

echo
if [ "$failures" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$failures check(s) failed" >&2
  exit 1
fi
