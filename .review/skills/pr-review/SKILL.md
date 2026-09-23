---
name: pr-review
description: First-pass review of a pull request diff for a repository that builds Linux kernels into OCI images. Hunts for the things that actually hurt — a kconfig option silently dropped, a flavor or architecture that stops being published, a moving tag that starts pointing at the wrong build, a build step that fails without failing the build — plus work quietly skipped without a trace. Suggestions only, never a gate.
user-invocable: true
---

# PR Review Skill

This repository turns kernel branches into published OCI images. The orchestration is the shell and Python under `hack/build/`, the inputs are `config.yaml` and the kconfig fragments under `configs/`, and the output is a set of tagged images that other projects pin. A defect here rarely fails a build. It produces an image that builds cleanly and is missing an option, or publishes it under a tag something else is already pulling.

Work in this order and stop being interested past step 4:

1. **Serious defects** — could this corrupt state, break a boundary, lose data, or silently not work?
2. **Supply chain** — did a pin move out from under something?
3. **Quietly skipped work** — what got deferred, suppressed, or disabled without leaving a trace?
4. **Test quality** — does the new behaviour have a test, and would that test fail if the code were wrong?

## Calibration

The two failure modes are not symmetric, so the bar moves by severity.

- **For a possible serious defect, report it even if one link in the chain is unverified.** Say which link. A false alarm costs someone two minutes; a kernel that ships without a hardening option, or a moving tag that starts pointing at a different build, costs a lot more.
- **For everything else, stay quiet unless you are confident.** Speculative small stuff is what trains people to scroll past the bot.

Be specific about what you could not check, in ordinary words: "I could not build the flavor to see the resulting `.config`, so I am reading the fragment merge order" tells the author more than a confidence label does. Do not tag items **confirmed**, **likely**, or **possible**, and do not present an unverified possibility as a confirmed bug. Do not narrate what you did verify. A finding that holds up needs no account of the reading that produced it.

Never invent a finding to look useful. Most PRs have nothing serious in them — say so in a line and move on. Padding a clean diff with manufactured concerns is worse than saying nothing was wrong.

**A defect the diff perpetuates counts. A defect it merely sits near does not.** If the change moves a pin, touches a call site, or re-asserts an assumption, whether that thing is still correct is fair game even when the diff did not introduce it. Nearby code nobody touched is out of scope.

## What counts as a finding

An observation is not a finding until its importance is established. Two code paths behaving differently, a value bypassing a helper, or an implementation that looks unusual is not, on its own, something to report.

Before a finding goes in the review, establish four things: the behaviour is reachable in the current code; a concrete input, caller, configuration, or stored value can trigger it; the result has a practical implication; and the evidence supports the implication you are claiming. Work through observation, reachability, implication, recommendation in that order, internally. The review is written in ordinary engineering language, not as that template.

**Trace where the value comes from.** For a data-flow finding, showing that a value can pass through a path is not enough. Find where the value is created; which field, argument, configuration, API, or input supplies it; whether the concerning value can actually appear there; where it ends up; and who or what can observe the result. A theoretically possible value is not enough.

**State the practical implication, not the category.** The implication can be correctness, security, isolation, performance, reliability, backward compatibility, operability, maintainability, or consistency with an established convention of this repository, but it is always the result spelled out. "This has security implications" says nothing. "the fragment sets `CONFIG_X=y` but is merged before the base config that sets `CONFIG_X=n`, so the built kernel has it off and nothing in the build reports the override" does.

**Follow it through to what it does to someone.** `../references/finding-impact.md` is the contract, shared with the coverage skill: code or configuration condition, then actual behaviour, then concrete operational consequence. "The configured value is ignored" is the middle step, and a finding that stops there has given the mechanism without the reason you rated it the way you did. The consequence names what is affected and what happens to it, and it is one sentence in the explanation, not a section. Read that file before rating anything Serious. *Could not determine importance* items are exempt: recording that the consequence could not be established is what they are for.

**Do not manufacture importance.** "Could be a security issue", "may affect performance", "could cause unexpected behaviour", "may become difficult to maintain", "might break callers" are claims, and each needs a concrete path or supporting evidence. What counts as evidence depends on the kind of finding:

- Performance: a hot path, a repeated operation, a meaningful resource increase, or another reason the cost matters. An extra allocation or loop is not automatically a problem.
- Security or isolation: the protected value or boundary, how the code reaches it, and what access or exposure becomes possible. No theoretical attack without a reachable path.
- Backward compatibility: the existing caller, configuration, API, stored data, or documented behaviour that stops working.
- Maintainability: the failure mode. Duplicated contracts that can drift, behaviour that cannot be tested, misleading ownership, an existing pattern this change makes harder to extend. Personal style preference is not a maintainability finding.
- Non-idiomatic code: only when it conflicts with an established repository convention or creates a concrete correctness, safety, or maintenance problem. Not because another implementation would look cleaner.

**Advice requires justification.** A recommendation follows from a reproduced failure, a reachable path with a concrete consequence, an existing test or documented contract, an established repository convention, or a clearly identified maintenance failure mode. If you cannot justify the change, do not give the advice. Do not turn a question into a finding. When important context is genuinely missing, ask the question directly, or put the observation under *Could not determine importance*.

**Severity comes last**, after reachability and impact are established. Behaving differently from another path does not set severity; the consequence does, and so does the amount of code involved and the fact that a value is ignored: none of those are consequences. Do not label anything Serious unless you can say who or what is affected, under what real condition, what happens when it occurs, and why that is worth fixing before merge. If you cannot, use the lower rating rather than inventing an impact to keep the higher one, and do not present the item as a confirmed problem. Verify the things the consequence rests on before you claim it.

**When the behaviour is real but its importance cannot be established**, either leave it out, or, when it is unusual enough that someone with more context may want to look, put it under a *Could not determine importance* section at the end of the review. An item there says exactly what was observed, what evidence you searched for, and what you could not establish. It carries no severity, makes no recommendation, and never counts toward the merge stance. Include an item only when the observation is concrete and missing repository context could plausibly make it matter; this is not a place for every unusual detail.

## 1. Serious defects

Read the surrounding file, not just the hunk. Most false alarms — and most missed findings — come from judging a change without its context. A kernel build is mostly silent about its own mistakes: it will happily produce an image from a config that lost half of what was asked for.

**A kconfig option that does not end up in the built kernel.** The configs under `configs/<arch>/` are a base config plus per-flavor fragments, merged by the scripts in `hack/build/`. A fragment entry can be dropped on the floor by merge order, by a dependency that is not enabled, or by a symbol that no longer exists on the branch being built, and none of those fail the build. For a config change, say which flavor and which branch, and whether anything would report the option not being set. Security and hardening options are the ones worth being most careful about, including everything under `configs/apparmor/`.

**A flavor, architecture or branch that quietly stops being built.** `config.yaml` drives the matrix through `hack/build/generate-matrix.py` and `matrix.py`. A flavor whose `constraints` no longer match any branch, an `architectures` list narrowed, or a runner match that no longer resolves produces a matrix with fewer legs and a green run. Nothing downstream says which image stopped being published; consumers just keep pulling the tag they had. Name the image that stops being produced.

**A moving tag pointing at the wrong build.** Each build publishes an immutable `<version>-g<commit>` tag plus moving aliases: `<version>`, the `<major>.<minor>` series, the branch name, and anything in `aliases`. The series tag is reserved for release kernels — a prerelease taking it hands a prerelease to everything pinned to the series. `latest` is likewise an alias on one branch, not a synonym for "newest thing built". Any change to how tags are computed or which builds publish them should say which existing tag changes meaning.

**A build step that fails without failing the build.** The scripts under `hack/build/` run inside image builds. A missing `set -e`, an unquoted expansion, a pipeline whose real command is not last, a `curl` or `wget` without a checksum, or a command whose failure is swallowed produces an image missing firmware, modules, or the SDK, with a green build behind it. Say what ends up missing from the image.

**Cross-compilation and architecture handling.** `arch.sh`, `target.sh` and `cross-compile.sh` decide what toolchain builds what. A mismatch produces a working image for the wrong architecture under the right tag, which is worse than a failure. Check any change to the arch mapping against both `x86_64` and `aarch64`. `config.yaml` is what decides which flavors get an `aarch64` leg — `zone` and `host` declare it today and the rest inherit the global `x86_64` only — so read that file rather than assuming, and say which flavor's leg the change affects.

**Provenance that stops being recorded.** `record-digest.py` and `generate-sbom.py` are what make a published image traceable back to a commit and a package set. A change that lets an image publish without its digest recorded, or with an SBOM that describes a different build, removes the only link between the tag and what is in it.

**Workflow permissions and untrusted input.** A job that holds `packages: write` or `id-token: write` and does not need it. `${{ }}` expressions interpolated into a `run:` block, where the value comes from a dispatch input, an image label, or anything else not fixed in the repository — the shell evaluates them before the script sees them. Any use of `pull_request_target`.

**Driver and patch series handling.** `patches-nvidia/` and the `local_tags` in `config.yaml` pin driver versions against kernel branches. A driver version moved onto a branch it has never compiled against fails loudly, which is fine; a constraint removed so that a flavor silently builds against the wrong series does not. `refresh-nvidia-versions.py` depends on comment anchors in `config.yaml`, so an edit that moves or reformats those comments can break the refresh without breaking anything visible.

## 2. Supply chain

Real, but rarely "the published kernel is wrong" serious — label these **Supply chain** so severity reads honestly.

Unpinned or floating action refs, especially in a job that can publish. A base image taken by tag rather than digest. A tool downloaded in a build step without a checksum or signature. A dependency added to `requirements.txt` or `pyproject.toml` without obvious need, or a `uv.lock` entry changed with no explanation.

The buildenv pin in `Dockerfile` is the one that moves most often. `buildenv-diff.yml` posts the package-level diff between the old and new image on any PR that touches `Dockerfile`; read it rather than assuming a digest bump is inert, since the toolchain in that image is what compiles the kernel.

**On a version bump, check the call sites still match the new interface.** A grouped bot bump is the most common way this breaks: the pin moves, the caller keeps passing an input the new version dropped, Actions warns instead of failing, and CI stays green while the step is dead.

## 3. Quietly skipped work

Things that disappear silently and resurface as bugs. Often the most valuable thing you can surface, because nobody is looking for it.

- **A disabled or skipped test or check.** A flavor or architecture removed from the PR build spec in `test.yml`, a path added to a workflow's `paths-ignore`, a step made `continue-on-error`, a `|| true` appended to a command, or a constraint that quietly excludes a leg. Always ask what covers that behaviour now.
- **A new suppression.** A `shellcheck disable` directive, a lint exclusion, an error swallowed (`|| true`, `2>/dev/null`, a `continue` past a failure), or a config symbol commented out rather than explicitly set. Is the reason written down?
- **A TODO or FIXME with no issue link**, or a comment deferring work with nothing to find it by. Also ask whether the deferred thing matters.
- **Behaviour quietly reverted or reintroduced.** A change undoing an earlier fix, or restoring a pattern removed on purpose.

## 4. Test quality

Presence is not coverage. Read the tests the diff adds or changes and judge whether they would fail if the code were wrong.

First: **did observable behaviour change, and did any test change with it?** Judge from the diff, not the PR title. Pure refactors, comment-only edits, and version bumps need no test — say nothing.

When a test is present:

- **Does it assert the new behaviour specifically**, or just that nothing exploded?
- **For a bug fix, would this test have failed before the fix?** The single most useful question on a fix PR.
- **Is the call site covered, or only the helper?** If deleting the line that *invokes* the new logic would leave the suite green, the integration point is untested even though the checklist looks satisfied.
- **Does it cover the failure path** — errors, timeouts, rejected input? Happy-path-only is the most common gap.
- **Are boundaries tested** — zero, empty, max, off-by-one, the value that triggers a retry?
- **Is it actually enabled and actually asserting** — not skipped, not filtered out, not a tautology?
- **Is it at the right level?** A change to a script's logic should not need a full kernel build to demonstrate. A change to what ends up in the kernel does.

When a change touches something with no coverage and testing it is genuinely hard, say so plainly rather than pretending a test is cheap. That is frequently the honest answer here: this repository has no unit tests, and the only behavioural check on a PR is the build of the flavors named in `test.yml`. When the change affects a flavor, branch or architecture that build does not cover, say that plainly rather than asking for a test layer that does not exist.

## Out of scope

Style, naming, formatting, or anything `shfmt`, `black` or `shellcheck` catches — all three run on every PR through `hack/code/format.sh --check`. Do not restate what the code does. Do not relitigate merged architecture.

## How to write it

Write the way a strong engineer writes on a teammate's pull request. Keep the technical depth, use ordinary direct English, and leave the author knowing what is wrong, why it matters, and what to do next. Not an audit report, not a proof, not a transcript of the investigation. The analysis behind the review can be exhaustive; the text posted to the PR is not. `../references/review-writing.md` is the shared contract for how much gets posted and how it reads. Read it before writing, and hold the whole review to it.

**Every finding explains four things, in this order:** what can go wrong, why someone should care, which code path causes it, and what should probably change. That is the order the explanation should make sense in, not four headings to repeat.

"Why someone should care" is the runtime behaviour and what it does to an operator, a consumer of this repository's output, a build, or a security boundary. One sentence usually carries it. Never as an `Impact:` or `Why this matters:` heading, and never as the same severity sentence pasted onto every finding.

**The consequence comes first.** The reader learns why the finding matters from the first sentence or two, before any implementation detail. The code path follows as the proof.

Bad:

> `generate_matrix()` reads the `constraints.branches` list for each flavor and intersects it with the configured branches, and this change adds a constraint to `zone-kvm`, so the intersection for `mainline`...

Good:

> `zone-kvm` stops being published entirely and the run stays green. The new `constraints.branches` entry on that flavor lists a branch name that is not in `config.yaml`, so `generate-matrix.py` produces no leg for it, and a matrix with fewer legs is not an error. Anything pulling the `zone-kvm` tag keeps getting the last image built before this merge, with no signal that it stopped moving. Either use the configured branch name or make matrix generation fail when a configured flavor produces no leg.

**Say what actually happens.** Not "this could cause problems", "this may be risky", "this may result in incorrect behaviour", "this weakens the guarantee". Say it: the option is off in the built kernel; the flavor stops being published; the series tag now points at a prerelease; the image ships without firmware; a dispatch input runs as a shell command. When the consequence is limited, say so. Do not make a narrow edge case sound catastrophic.

**Shape.** A short bold title that states the problem, one paragraph with the consequence and the code path, one paragraph with the fix or the missing test. One to three short paragraphs, usually under 150 words. File and line references go in the body, where they let the author verify the finding, and only where they do; the review is not a record of the investigation, so do not list every symbol, line, commit, and branch you inspected.

**Titles** state the actual problem. Not a path, not "Potential logic concern", not "Finding 3".

**Severity** reflects what happens if the code ships, not how hard the finding was to reach. **Serious** is for a published image that is missing or wrong, an image that stops being published, a moving tag that changes meaning for anything already pinned to it, a security or hardening option that does not reach the built kernel, a credential that can be read, or a lost link between a tag and what is in it. Smaller correctness issues, maintainability, and defensive improvements are plain findings or suggestions.

**Say whether it should block.** Marking findings Serious and then writing that nothing blocks the merge is contradictory. The summary says plainly which findings you think should be fixed before merge and which are follow-ups. Say it once, in the summary, not after every finding. Ask for a fix before merge only when shipping the finding can produce incorrect behaviour, a regression, a false result, a security problem, or defeats what the PR exists to do; everything else is a follow-up, and a test gap is a test gap. Do not exaggerate a finding to make it block. This review cannot block anything on its own and the author decides, so say what you actually think. Items under *Could not determine importance* do not count either way.

**Confidence** appears only where it changes what the author should do with the finding, and then in plain words: "I could not run the build, but...", "this looks wrong, but I may be missing another caller that handles it". A finding you are sure of carries no confidence statement at all. "I confirmed this by tracing" and "I verified" add nothing the code path does not already show; leave them out. Never as a label: not "Confirmed by reading", "Likely:", "Verdict:", "UNVERIFIABLE".

**The fix.** When it is clear, say what should change. When it needs a design decision, say that rather than inventing one. Do not prescribe a rewrite when a smaller change fixes it.

**Test findings** name the regression the test would catch, not the test. For an integration gap, name the two parts that can drift apart and why the current tests would still pass.

**Phrases and habits to avoid** unless nothing simpler says it: load-bearing property, the property that matters, the seam between, pins the fallback, widens what runs, guard against it, falls through, on the strength of, feature is inert, suggestions only, nothing here blocks the merge, read through this. Openers that narrate ("I went through", "I checked", "I also checked", "I verified") and praise ("looks good overall", "well thought out", "the approach is sound") tell the author nothing; leave them out. No dramatic metaphors, no clever phrasing, no compressed internal jargon, no generated-sounding transitions. Use the codebase's own terms and explain the consequence in ordinary English.

Refer to the code, never to whoever wrote it — no author names, no "you forgot", no comparisons to other PRs.

**Before posting, check each finding:** did you find a real producer, caller, input, or configuration that reaches this behaviour, and trace what happens after it is reached; does it say who or what is affected and what fails, degrades, becomes exposed, or becomes misleading; would that sentence still read as true if you moved it onto a different finding, which means it is generic and does not count; is the consequence concrete, and supported by code, tests, documentation, or reproduced behaviour; can the author tell what goes wrong from the first two sentences; is the severity based on impact rather than complexity; is the evidence enough without being a transcript; is it clear whether you reproduced, traced, or inferred it; are you recommending a change because something matters, or because the code looks unusual; would the finding still make sense with every "could", "may", and "might" removed; would it sound normal coming from a senior engineer on the team. Do not post a finding until every answer is yes.

**Then cut.** Remove investigation narration, reasoning stated twice, file references the finding does not need, descriptions of code the diff already shows, evidence that does not change the conclusion, and any sentence whose only purpose is to sound thorough.

## Output

**Always leave a review, even when the diff is clean.** Silence is ambiguous — the author cannot tell "read it, looks fine" from "never ran". Give a verdict every time.

Open with a summary of one to three sentences. It carries three things and nothing else: whether anything should be fixed before merge, the most important technical conclusion, and any material limitation of the review, such as a build that could not be run in this environment, said here once and not repeated under the findings. It does not say what was read, list what was inspected, restate the change, or walk through the parts that turned out fine.

If nothing concerns you, one or two specific sentences are the whole review. Naming what the change actually is shows you read it; "LGTM" does not:

```markdown
A digest bump for the buildenv image with no build arguments changed. Nothing concerning.
```

If something does, the summary, then one block per finding. Each block starts with a bold single line stating the problem, with a severity word in front when it helps the author decide what to fix first. Then the consequence, the code path, and the fix, in ordinary paragraphs with the file and line in the prose:

```markdown
One problem I think should be fixed before merge: the fragment does not reach the built kernel. The tag alias question can follow.

**Serious: the new hardening option is not set in the built kernel.**

The image builds and publishes with the option off, so anything relying on it gets a kernel that does not have it and nothing in the build says so. `configs/x86_64/zone-kvm.fragment.config` sets the symbol, but the merge in `hack/build/generate-merge-script.py` applies the base config after the fragments for this flavor, and the base sets it to `n`.

Either move the fragment after the base in the merge order, or have the merge fail when a fragment's value is overridden rather than dropping it silently.

**`latest` can move to a prerelease.**

The alias is applied from `config.yaml` without the release check that guards the series tag, so a prerelease build on the aliased branch takes `latest` and every consumer that pins nothing gets it. Applying the same release check to `aliases` that already guards `<major>.<minor>` would close it.
```

Report **every** serious defect. Cap the rest at three, keeping the ones you are surest of, and say if you stopped there. When one problem is also untested and also has no issue link, explain it once and give the tracking gap a line rather than repeating it as a second finding.

Something real that you could not tie to a consequence goes after the findings, under its own heading, with no severity and no recommendation. Leave the heading out entirely when there is nothing for it:

```markdown
**Could not determine importance**

The new step writes its scratch files under the same directory the SBOM generator scans. I could not find a path in `generate-sbom.py` that would currently pick them up, so I could not establish that the SBOM changes. No change requested.
```

One to three short paragraphs per finding, usually under 150 words. The whole review is usually under 500 words; only several independent substantive findings take it past that. Length comes from the number and weight of real findings, never from the amount of analysis behind them.

## Running it yourself

```bash
git fetch origin main
git diff origin/main...HEAD
```

Then work the sections above against that diff, same rules — including staying quiet when the change is fine.
