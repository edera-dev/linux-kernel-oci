---
name: test-coverage-review
description: Review a pull request in a kernel image build repository for the check that is missing, not for how many tests it has. This repository has no unit tests: the checks are the formatters, the linters, and the subset of the build matrix that runs on a PR. Works out what the change can realistically break, decides whether anything on the PR would catch it, and says so. Advisory only.
user-invocable: true
---

# Test coverage review

Bugs keep reaching a release that a check at the right layer would have caught. This skill exists to name that check while the PR is still open.

The job is not to judge whether a PR has "enough tests". It is to understand what the change does, work out how it could realistically be wrong, read the checks that exist, and decide whether those checks would fail if it were. If they would not, say which scenario is uncovered and what check would catch it. If they would, say so in a line and stop.

Nothing here blocks a merge. The review is comment-only, and every line of it is the author's to act on or ignore.

## How to work

### 1. Understand the change

Read the diff, then the surrounding code. Write down, for yourself, one sentence per behaviour that changed. Judge from the code, not from the PR title or description.

Sort the change into one of these before going further:

- **No behaviour change.** Dependency and image bumps, comment and doc edits, renames, formatting, CI wiring, pure refactors that move code without altering what it does. These need no test. Say so in a line and stop.

  A bump is not a behaviour change of this repo, even across major versions. The test for a bump is the existing checks passing. Do not go reading the bumped dependency's changelog for something to say. The only exception is a bump that also edits a call site in this repo; then review that call site like any other change, and nothing else.
- **Test-only change.** Ask only whether the changed test still proves what it claims to. Nothing else.
- **Behaviour change.** Continue.

### 2. List how it could be wrong

For each behaviour that changed, write down the concrete ways it could be wrong in this codebase. Not "edge cases" in general. Ask:

- What input would make the new code do the wrong thing? Where does it come from: `config.yaml`, a kconfig fragment, a kernel branch's own Makefile, a driver version, a runner label, a workflow input?
- Does the change behave differently per flavor, per architecture, or per branch? `zone` is the only flavor published for `aarch64`, and some flavors are constrained to one branch, so a change that looks uniform often is not.
- What happens on the failure path: the symbol that does not exist on that branch, the driver that does not compile, the download that 404s, the runner that does not match?
- If this is a bug fix, what exactly was the bug, and what would have failed before the fix?
- If the change affects what gets published — a tag, an alias, a digest record, an SBOM — who is already pinned to the thing it changes?
- Is the affected flavor, branch or architecture actually in the PR build at all?

Keep only the ones a strong engineer here would agree are realistic. Three is plenty. If you cannot state how someone would actually hit it, drop it.

Stay on the diff. The failure modes come from the lines the PR changed and the code that directly calls or is called by them. If you find yourself reading code the PR did not touch to build a case, the case is not about this PR.

### 3. Read the checks that exist

Find every check that touches the changed behaviour, then read it. `references/test-layers.md` says where each kind of check lives in this repo and what CI actually runs on a PR. Look in:

- `.github/workflows/test.yml`, which is the only behavioural check on a PR: it calls the matrix workflow with a fixed spec and `publish: false`. Read the spec and work out whether the change is inside it;
- `.github/workflows/lint.yml`, which runs `hack/code/format.sh --check` — `shfmt`, `black` and `shellcheck`;
- `.github/workflows/buildenv-diff.yml`, which runs only on PRs touching `Dockerfile`;
- the scripts in `hack/build/` themselves — several validate their own inputs, and that validation is sometimes the only check a change has.

There are no unit tests in this repository. Do not look for a test file; look for whether the PR build covers the leg the change affects.

For each failure mode from step 2, decide honestly: covered, covered on one path only, covered by a check that would pass anyway, or not covered. "A test in that file exists" is not "covered". Read the assertions and ask what would make them pass when the code is wrong. When a test asserts two values are equal, name what else could make them equal: both empty, both a default. When a test asserts something happened, work out what it would see if it had not. If you find such a path, that is a gap in the test itself, and it is worth a line even when the production code is right.

### 4. Check what has already been said

Read the PR description, the review comments, the review threads, and any comment left by another bot. If someone has already raised a gap, do not raise it again in your own words. If the author explained why a test was skipped, take the explanation at face value unless it is wrong on the facts. A test the author says is hard to write is usually hard to write.

Your own earlier review does not count as already said. When this review runs again on a new push, the Test Coverage section of the review carrying the `<!-- pr-review -->` marker is the one you are about to replace. Re-derive the verdict from the current diff; if the gap is still there, say it again.

### 5. Decide

Report a gap only when all of these hold:

- the failure mode is realistic and specific to this change;
- a check at some layer would actually catch it;
- the check is proportionate to the change. Asking for a unit test framework this repository does not have is not a finding. Asking for the changed flavor to be added to the PR build spec is.

Everything else stays unsaid. Most PRs in this repo will get the one-line "looks right" comment, and that is the correct outcome, not a failure to find something. A reviewer that invents a gap on every PR is one people stop reading, and then it misses the real one.

A gap is an observation until its importance is established. Before it goes in the review, say who hits the failure and how, what happens when they do, and why the current checks let it through. If the gap only makes sense with a "could", "may", or "might" in it, it is not established. When you cannot find the input, caller, or configuration that reaches the failure, leave it out rather than dress it up. This review has no "could not determine importance" section: a gap with no reachable failure is not a gap.

`../references/finding-impact.md` is the shared contract for that, and it applies here with one difference. A gap describes a defect that has not happened yet, so the consequence is allowed to be conditional — but the condition has to be concrete. "A build on the mainline branch after this merge produces no `zone-kvm` image, and the run still passes because a matrix with fewer legs is not an error" names the condition and the result. "This could cause build issues" names neither.

When you have read the changed code and the checks around it and found nothing, stop there. Do not go hunting through the rest of the repository hoping something turns up. Finding nothing after a careful read is the answer.

A well-covered change with one more branch you could name is clean. When the PR already covers the failure paths of the new code at the right layer, report a remaining branch only if hitting it in production is realistic and the outcome would be wrong, not merely unexercised. "This arm has no test" is not a finding on its own.

Two shapes come up constantly and are worth naming so you weigh them properly:

- **The change is outside what the PR builds.** `test.yml` rebuilds one branch and a fixed subset of flavors. A change to a flavor, architecture or branch outside that spec is not exercised by anything on the pull request, no matter how it looks. This is the single most common real gap here, and naming it is usually more useful than proposing a new check.
- **The failure is silent by construction.** A dropped kconfig symbol, a matrix leg that produces nothing, a publish step skipped by a constraint: all of these leave a green run. Say what would have to be asserted for the build to notice, and where that assertion would go.

Pick the smallest thing that would catch the failure. A validation inside the script that already owns the input, for anything the script can check about its own arguments. An added leg in the PR build spec, for a flavor or architecture the change affects. A check in the matrix generator, for a configuration that should never produce zero legs. Do not propose a test harness this repository does not have.

## What to write

One review, short enough to read without scrolling. Write it the way you would say it to a teammate, not the way a report reads. Short sentences, one idea each. Do not compress the whole chain of reasoning into one long sentence. `../references/review-writing.md` is the shared contract for how much gets posted and how it reads; read it before writing. The section answers three questions: what behaviour is covered, what meaningful behaviour is not, and whether there is a gap the author should act on. The whole section is usually under 150 words.

**When the checks fit the change**, one or two sentences naming the behaviour they cover, at the level of the path or the scenario. Then stop. The sentence naming what is covered is the verdict; do not put "testing looks right" or another verdict phrase in front of it. Do not walk through every arm, case, or test name to show the coverage is there. Do not append observations, caveats, or things worth knowing. If a gap from an earlier round is now covered, leaving it out says so; do not add a paragraph confirming it. If it is not a gap, it does not go in the review.

Bad:

> The PR build covers this. `test.yml` rebuilds the LTS branch with the host, zone and zone-nvidiagpu flavors, each of which exercises the changed merge path, and the formatter and linter both pass on the changed scripts...

Good:

> The PR build rebuilds the three flavors that go through the changed merge path, so a config that fails to apply would fail there.

```markdown
Nothing here needs a check. It's a comment fix in a build script.
```

**When there is a gap**, open with a plain line saying how many there are and whether you think the checks should land with this PR or can follow, then one block per gap. Say what is missing. Do not introduce it with a description of the shape of the problem:

```markdown
One gap. I'd fix it with this PR, since it decides whether the change is exercised at all.

**Nothing on this pull request builds the flavor the change affects.**

`zone-amdgpu` can stop producing an image and the PR stays green, because `test.yml` calls the matrix with `flavor=host,zone,zone-nvidiagpu` and this change only alters the amdgpu fragment path. The first sign would be a consumer pulling a tag that stopped moving.

Adding `zone-amdgpu` to the spec in `test.yml` would build it here. If that is too slow to run on every PR, a check in `generate-matrix.py` that fails when a configured flavor produces no leg would at least catch the disappearing-image case.
```

Each gap states four things: the behaviour or transition that has no coverage, the defect that can escape because of it, what that defect does to a consumer, an operator, or a supported operation when it escapes, and the check to add with its layer, file, and assertion. Written in that order, the first sentence carries the consequence and the last one names the assertion that protects against it. A test proposed without the failure it prevents is not a gap. Two or three short paragraphs rather than one dense one, and under about 120 words; with the opening line the section stays under about 150, and only several independent gaps take it past that. Leave out how you traced it. Name the file and the function so the author can go straight there, and name the assertion, not just "add a test for X".

Name the regression, not the test. For an integration gap, name the two parts that can drift apart and why the current checks would still pass.

Cap it at three gaps. If there are more, pick the three most likely to bite and say you stopped there.

### Wording

Write like a strong engineer on a teammate's pull request, not like a report. Specific, direct, easy to act on, and the consequence before the mechanism.

- Say what actually happens. Not "this may result in incorrect behaviour" or "this weakens the guarantee" but the real outcome. When the consequence is limited, say so.
- Do not narrate. Not what you read, traced, drove, or checked; say what is covered and what is not. If something could not be run in this environment, say so once in the opening line and not again per gap.
- No enumeration of test names or arms to show coverage exists. Name the behaviour the checks cover.
- No praise or filler. "Testing looks right", "good coverage", "well tested", "looks good overall" carry nothing; the sentence naming what is covered replaces them.
- No scores, grades, severities, or "risk" language. No headings other than the bold line naming the gap.
- No asides. Nothing "for the record" or "worth knowing", no observations that are not a gap.
- No hedging filler ("it might be worth considering", "you may want to"). Say what the check is. Real uncertainty is different and worth saying plainly. Never as a label: not "Confirmed by reading", "Likely:", "Verdict:", "UNVERIFIABLE".
- No generic asks. "Add more integration tests" and "increase coverage" are never the answer. If you cannot name the scenario and the assertion, you do not have a finding.
- No metaphors or compressed jargon where plain English is shorter: load-bearing, the seam between, escape hatch, widens what runs, guard against it, falls through, feature is inert, read through this. Use the codebase's own terms and say what the check asserts.
- No boilerplate disclaimer. Not "suggestions only", not "nothing here blocks the merge". Whether the checks should land with the PR belongs in the opening line, said once.
- Refer to the code, never to the person. No author names, no "you forgot", no comparisons with other PRs.
- Do not restate what the change does beyond what the reader needs to place the gap.

## Running it yourself

```bash
git fetch origin main
git diff origin/main...HEAD
```

Work the steps above against that diff. On an open PR, also read the review comments so you do not repeat them:

```bash
gh pr view <n> --comments
gh api repos/edera-dev/linux-kernel-oci/pulls/<n>/comments --jq '.[].body'
```
