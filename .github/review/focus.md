# Review focus

What the advisory review checks look for in this repository. The shared
workflow in `edera-dev/actions` supplies the review method; this file supplies
everything specific to this repository, and `test-layers.md` beside it says
where checks live and what runs on a pull request.

Each section starts at its `<!-- focus: NAME -->` line and runs to the next
one. The templates under `advisory-review/templates/` in `edera-dev/actions`
fix the names and show where each section lands. `FORK_SCOPE` is optional;
every other section is required, and a name no template uses fails the run.

<!-- focus: INTRO -->
This repository turns kernel branches into published OCI images. The orchestration is the shell and Python under `hack/build/`, the inputs are `config.yaml` and the kconfig fragments under `configs/`, and the output is a set of tagged images that other projects pin. A defect here rarely fails a build. It produces an image that builds cleanly and is missing an option, or publishes it under a tag something else is already pulling.

<!-- focus: SERIOUS -->
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

<!-- focus: SUPPLY -->
## 2. Supply chain

Real, but rarely "the published kernel is wrong" serious — label these **Supply chain** so severity reads honestly.

Unpinned or floating action refs, especially in a job that can publish. A base image taken by tag rather than digest. A tool downloaded in a build step without a checksum or signature. A dependency added to `requirements.txt` or `pyproject.toml` without obvious need, or a `uv.lock` entry changed with no explanation.

The buildenv pin in `Dockerfile` is the one that moves most often. `buildenv-diff.yml` posts the package-level diff between the old and new image on any PR that touches `Dockerfile`; read it rather than assuming a digest bump is inert, since the toolchain in that image is what compiles the kernel.

**On a version bump, check the call sites still match the new interface.** A grouped bot bump is the most common way this breaks: the pin moves, the caller keeps passing an input the new version dropped, Actions warns instead of failing, and CI stays green while the step is dead.

<!-- focus: SKIPPED_TEST_FORMS -->
A flavor or architecture removed from the PR build spec in `test.yml`, a path added to a workflow's `paths-ignore`, a step made `continue-on-error`, a `|| true` appended to a command, or a constraint that quietly excludes a leg.

<!-- focus: SUPPRESSION_FORMS -->
A `shellcheck disable` directive, a lint exclusion, an error swallowed (`|| true`, `2>/dev/null`, a `continue` past a failure), or a config symbol commented out rather than explicitly set.

<!-- focus: RIGHT_LEVEL -->
A change to a script's logic should not need a full kernel build to demonstrate. A change to what ends up in the kernel does.

<!-- focus: NO_TEST_LAYER -->
That is frequently the honest answer here: this repository has no unit tests, and the only behavioural check on a PR is the build of the flavors named in `test.yml`. When the change affects a flavor, branch or architecture that build does not cover, say that plainly rather than asking for a test layer that does not exist.

<!-- focus: OUT_OF_SCOPE -->
Style, naming, formatting, or anything `shfmt`, `black` or `shellcheck` catches — all three run on every PR through `hack/code/format.sh --check`.

<!-- focus: CALIBRATION_COST -->
a kernel that ships without a hardening option, or a moving tag that starts pointing at a different build, costs a lot more.

<!-- focus: CANNOT_CHECK_EXAMPLE -->
I could not build the flavor to see the resulting `.config`, so I am reading the fragment merge order

<!-- focus: IMPLICATION_EXAMPLE -->
"the fragment sets `CONFIG_X=y` but is merged before the base config that sets `CONFIG_X=n`, so the built kernel has it off and nothing in the build reports the override" does.

<!-- focus: SERIOUS_DEFINITION -->
a published image that is missing or wrong, an image that stops being published, a moving tag that changes meaning for anything already pinned to it, a security or hardening option that does not reach the built kernel, a credential that can be read, or a lost link between a tag and what is in it

<!-- focus: SAY_WHAT_HAPPENS -->
the option is off in the built kernel; the flavor stops being published; the series tag now points at a prerelease; the image ships without firmware; a dispatch input runs as a shell command

<!-- focus: WRITE_BAD -->
`generate_matrix()` reads the `constraints.branches` list for each flavor and intersects it with the configured branches, and this change adds a constraint to `zone-kvm`, so the intersection for `mainline`...

<!-- focus: WRITE_GOOD -->
`zone-kvm` stops being published entirely and the run stays green. The new `constraints.branches` entry on that flavor lists a branch name that is not in `config.yaml`, so `generate-matrix.py` produces no leg for it, and a matrix with fewer legs is not an error. Anything pulling the `zone-kvm` tag keeps getting the last image built before this merge, with no signal that it stopped moving. Either use the configured branch name or make matrix generation fail when a configured flavor produces no leg.

<!-- focus: CLEAN_EXAMPLE -->
A digest bump for the buildenv image with no build arguments changed. Nothing concerning.

<!-- focus: OUTPUT_EXAMPLE -->
One problem I think should be fixed before merge: the fragment does not reach the built kernel. The tag alias question can follow.

**Serious: the new hardening option is not set in the built kernel.**

The image builds and publishes with the option off, so anything relying on it gets a kernel that does not have it and nothing in the build says so. `configs/x86_64/zone-kvm.fragment.config` sets the symbol, but the merge in `hack/build/generate-merge-script.py` applies the base config after the fragments for this flavor, and the base sets it to `n`.

Either move the fragment after the base in the merge order, or have the merge fail when a fragment's value is overridden rather than dropping it silently.

**`latest` can move to a prerelease.**

The alias is applied from `config.yaml` without the release check that guards the series tag, so a prerelease build on the aliased branch takes `latest` and every consumer that pins nothing gets it. Applying the same release check to `aliases` that already guards `<major>.<minor>` would close it.

<!-- focus: UNKNOWN_EXAMPLE -->
The new step writes its scratch files under the same directory the SBOM generator scans. I could not find a path in `generate-sbom.py` that would currently pick them up, so I could not establish that the SBOM changes. No change requested.

<!-- focus: IMPACT_WORKED_EXAMPLE -->
The fragment sets the symbol but is merged before the base config that clears it, so the published kernel has the option off. Anything that pins this tag and relies on the option gets a kernel without it, and neither the build nor the image metadata says so.

<!-- focus: HOW_WRONG -->
- What input would make the new code do the wrong thing? Where does it come from: `config.yaml`, a kconfig fragment, a kernel branch's own Makefile, a driver version, a runner label, a workflow input?
- Does the change behave differently per flavor, per architecture, or per branch? `zone` is the only flavor published for `aarch64`, and some flavors are constrained to one branch, so a change that looks uniform often is not. The PR build covers the `zone` aarch64 leg; it does not cover flavors outside its spec.
- What happens on the failure path: the symbol that does not exist on that branch, the driver that does not compile, the download that 404s, the runner that does not match?
- If this is a bug fix, what exactly was the bug, and what would have failed before the fix?
- If the change affects what gets published — a tag, an alias, a digest record, an SBOM — who is already pinned to the thing it changes?
- Is the affected flavor, branch or architecture actually in the PR build at all?

<!-- focus: WHERE_TO_LOOK -->
- `.github/workflows/test.yml`, which is the only behavioural check on a PR: it calls the matrix workflow with a fixed spec and `publish: false`. Read the spec and work out whether the change is inside it;
- `.github/workflows/lint.yml`, which runs `hack/code/format.sh --check` — `shfmt`, `black` and `shellcheck`;
- `.github/workflows/buildenv-diff.yml`, which runs only on PRs touching `Dockerfile`;
- the scripts in `hack/build/` themselves — several validate their own inputs, and that validation is sometimes the only check a change has.

There are no unit tests in this repository. Do not look for a test file; look for whether the PR build covers the leg the change affects.

<!-- focus: PROPORTIONATE -->
Asking for a unit test framework this repository does not have is not a finding. Asking for the changed flavor to be added to the PR build spec is.

<!-- focus: CONDITIONAL_EXAMPLE -->
"A build on the mainline branch after this merge produces no `zone-kvm` image, and the run still passes because a matrix with fewer legs is not an error" names the condition and the result. "This could cause build issues" names neither.

<!-- focus: TWO_SHAPES -->
- **The change is outside what the PR builds.** `test.yml` rebuilds one branch and a fixed subset of flavors. A change to a flavor, architecture or branch outside that spec is not exercised by anything on the pull request, no matter how it looks. This is the single most common real gap here, and naming it is usually more useful than proposing a new check.
- **The failure is silent by construction.** A dropped kconfig symbol, a matrix leg that produces nothing, a publish step skipped by a constraint: all of these leave a green run. Say what would have to be asserted for the build to notice, and where that assertion would go.

<!-- focus: SMALLEST_LAYER -->
Pick the smallest thing that would catch the failure. A validation inside the script that already owns the input, for anything the script can check about its own arguments. An added leg in the PR build spec, for a flavor or architecture the change affects. A check in the matrix generator, for a configuration that should never produce zero legs. Do not propose a test harness this repository does not have.

<!-- focus: COVER_BAD -->
The PR build covers this. `test.yml` rebuilds the LTS branch with the host, zone and zone-nvidiagpu flavors, each of which exercises the changed merge path, and the formatter and linter both pass on the changed scripts...

<!-- focus: COVER_GOOD -->
The PR build rebuilds the three flavors that go through the changed merge path, so a config that fails to apply would fail there.

<!-- focus: CLEAN_NOTHING -->
Nothing here needs a check. It's a comment fix in a build script.

<!-- focus: GAP_EXAMPLE -->
One gap. I'd fix it with this PR, since it decides whether the change is exercised at all.

**Nothing on this pull request builds the flavor the change affects.**

`zone-amdgpu` can stop producing an image and the PR stays green, because `test.yml` calls the matrix with `flavor=host,zone,zone-nvidiagpu` and this change only alters the amdgpu fragment path. The first sign would be a consumer pulling a tag that stopped moving.

Adding `zone-amdgpu` to the spec in `test.yml` would build it here. If that is too slow to run on every PR, a check in `generate-matrix.py` that fails when a configured flavor produces no leg would at least catch the disappearing-image case.
