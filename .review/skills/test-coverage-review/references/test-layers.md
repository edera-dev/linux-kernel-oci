# Where checks live in this repo, and what runs on a PR

This repository has no unit tests. Nothing here imports a build script and
asserts on it. The checks are the formatters, the linter, and a partial build.
Knowing exactly what that build covers is most of the job, because the usual
real gap is that the change falls outside it.

## Formatting and linting

`.github/workflows/lint.yml` runs `hack/code/format.sh --check` on every PR:
`shfmt -d` over every `hack/**/*.sh`, `black --check` over every
`hack/**/*.py`, and `shellcheck` over the shell files. The linter has no
autofix, so it runs in both modes of that script. Anything these three catch is
out of scope for a review.

## The PR build

`.github/workflows/test.yml` is the only thing on a pull request that executes
the build. It calls `matrix.yml` with a fixed specification and
`publish: false`, so it builds and throws the result away. Read the spec in
that file before deciding a change is covered.

The spec constrains branches and flavors only. `matches_constraints` in
`hack/build/util.py` ignores any key the constraint does not mention, so every
architecture a selected flavor declares in `config.yaml` is built — which means
the `zone` flavor's `aarch64` leg does run on a pull request. What the spec
leaves out is other branches and the flavors it does not name; a change that
only affects one of those is not built here at all.

`test.yml` also has `paths-ignore` for `configs/**` on push, because config
merges are built and published by `build.yml` instead. That does not apply to
pull requests, but it is worth knowing which workflow owns which path.

## The buildenv diff

`.github/workflows/buildenv-diff.yml` runs only on PRs that touch `Dockerfile`.
It pulls both the old and the new buildenv image, compares the package manifest
each one carries at `/usr/share/buildenv/packages.tsv`, and posts the
difference to the check summary. On a digest bump this is the evidence about
what actually changed in the toolchain.

## The review checks themselves

Three workflows belong to the advisory review checks rather than to this
repository's own validation: `pr-review-suggestions.yml` and
`pr-test-coverage.yml`, which produce this review, and
`pr-review-selftest.yml`, which runs the publisher's tests when that machinery
changes. They build, lint and test nothing this repository ships. Never count
them as coverage for a change.

## Everything else

`build.yml`, `buildenv.yml`, `refresh-nvidia.yml` and `digestabot.yml` are
`schedule`, `push` or `workflow_dispatch` and will not run on the pull request
under review. `matrix.yml` is `workflow_call` only.

## In-script validation

Several scripts under `hack/build/` validate their own inputs, and for a lot of
changes that validation is the only check there is. When proposing where a check
should go, this is usually the right answer: the script that already owns the
input is the cheapest place to assert something about it.

## Where a gap usually is

- The change affects a branch or a flavor the PR build's spec does not name.
  This is the common one. Architecture is usually not the gap: the spec sets no
  architecture constraint, so each selected flavor builds every architecture it
  declares.
- The failure is silent by construction — a kconfig symbol that does not apply,
  a matrix leg that produces nothing, a publish step a constraint skipped — so a
  green run proves nothing about it.
- A workflow change, which nothing on the pull request exercises if the workflow
  only runs on schedule or dispatch.
- A script that takes a new input and does not validate it, where the first sign
  of a bad value is a wrong image rather than a failure.
