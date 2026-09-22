# Skills

Skills used by the two advisory review checks that run on every pull request in
this repository. Both are comment-only and neither can block a merge.

| Skill | What it is for |
| --- | --- |
| `pr-review` | First-pass review of a diff. Hunts for the things that actually hurt in a kernel image build: a kconfig option that does not reach the built kernel, a flavor that stops being published, a moving tag that changes meaning, a build step that fails without failing the build. Suggestions only. |
| `test-coverage-review` | The check that is missing, not the check count. Works out how a change could realistically break, reads the checks that exist, and names the uncovered scenario and the check that would catch it, at the right layer. Suggestions only. |

`references/` holds what both skills share, so the rule has one copy:

- `review-writing.md` — how much of the review gets posted and how it reads.
- `finding-impact.md` — what a finding has to establish before it is worth
  posting: the code condition, the behaviour it produces, and what that does to
  someone.

The workflows that run these are `.github/workflows/pr-review-suggestions.yml`
and `.github/workflows/pr-test-coverage.yml`. Both publish through
`.github/scripts/post-pr-review.sh`, which fixes the review event to `COMMENT`,
so neither can approve a pull request or request changes on one. They share a
single review on the pull request, one labelled section each.

Either skill can also be run by hand against a local diff; each one ends with
the commands for that.
