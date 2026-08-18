# Kernel config maintenance

How to keep `configs/` honest across kernel version bumps, and how to use
`hack/build/analyze-fragment.py` to find problems before spending a build on
them.

For the flavor/variant layering model itself, see [`configs/README.md`](configs/README.md).
This document covers verification and upgrade hygiene.

## Setup

The analyzer needs `kconfiglib`, which is **not** in `requirements.txt` — it is
a dev-time tool, not a build dependency:

```bash
./hack/build/venv/bin/python -m pip install kconfiglib
```

All commands below are run from the repo root with `../linux-zone` as the
kernel source tree. They are `bash`, not `fish`.

## Six facts that cause most config bugs

Everything in this document follows from these.

**1. `select` ignores `depends on`.** A `# CONFIG_X is not set` line loses
silently if any reachable symbol selects X. There is no warning; the symbol just
comes back on. Disable at a symbol nothing selects and let `depends on` cascade
to everything under it.

**2. Symbols with no prompt cannot be set from a config file.** Their value
comes from `select`/`default` alone, so a line naming one is decorative. This
covers most of the DRM helper stack (`DRM_TTM`, `DRM_SCHED`, `DRM_EXEC`), plus
things like `HMM_MIRROR`, `VIDEO`, `SCREEN_INFO`, `FB_CORE`. Writing
`CONFIG_DRM_TTM=y` does not make it `y`; enabling something that selects it does.

**3. Unlisted symbols are not off.** They take their Kconfig default, which is
frequently `y`. "Not mentioned" and "disabled" are different states — which is
why turning a subsystem off requires explicit `# CONFIG_X is not set` lines
rather than deleting the enables.

**4. `# CONFIG_X is not set` is the only syntax for a disable.** It is
syntactically a comment, so any tooling that strips comments will silently drop
every disable in a fragment.

**5. When a symbol is declared twice, the last one wins — silently.** Nothing
warns you, and the two declarations can be hundreds of lines apart in unrelated
sections. `zone.config` carried `I40E=m` in the Intel block and `I40E=y` further
down, so the driver was built into vmlinux while the config appeared to say
module. It also carried `DEBUG_INFO_NONE=y` and `DEBUG_INFO_NONE=n`; the `=n`
won and BTF survived, but reordering the file would have silently killed
`DEBUG_INFO_BTF`. Duplicates spanning the two syntaxes (`CONFIG_X=y` early, `#
CONFIG_X is not set` late) are the same hazard and easy to miss by eye.

**6. A line can ask for a value and silently not get it.** If a prerequisite is
missing, Kconfig drops the request without a word. `CONFIG_NETDEVICES` was
absent from the aarch64 zone config and its Kconfig default is `default y if
UML` — i.e. `n` — so `CONFIG_VIRTIO_NET=y`, `CONFIG_XEN_NETDEV_FRONTEND=y` and
`CONFIG_HVC_XEN=y` all sat in the file resolving to nothing, and the zone
shipped with no network interface. `CONFIG_XEN` was likewise never enabled
while twenty Xen lines sat below it. Reading the config file tells you what was
*asked for*; only the resolved `.config` tells you what you got.

## The analyzer

```bash
./hack/build/venv/bin/python hack/build/analyze-fragment.py \
    configs/x86_64/zone.config --srctree ../linux-zone
```

Sections it reports:

| Section | Meaning |
|---|---|
| **Duplicate declarations** | Fact 5. Reported first, since a conflicting repeat makes every later section suspect |
| **Unknown symbols** | Not defined for this ARCH — deleted upstream, a typo, or another arch's option |
| **Disables that `select` can override** | Fact 1. These lines can be silently reverted |
| **New selectors since `<ref>`** | Only with `--since`. Drift introduced by a version bump |
| **Entries that do not take effect** | Fact 6. The line asks for one value, the kernel resolves another |
| **Entries with no effect** | Fact 2. The symbol has no prompt; the line does nothing, enable or disable |
| **Redundant disables** | Another disable already forces this off via `depends on` |
| **Enabled entries with disabled dependencies** | Requested on, but something it needs is off |
| **Reach of each disable** | How many symbols each line takes down — is one high-level line covering the subtree you meant? |

Useful flags:

- `--arch arm64` — defaults to `x86_64`. Everything the tool reports is
  per-arch; there is no cross-arch mode.
- `--base <.config>` — **strongly recommended.** Without a loaded config every
  symbol sits at its Kconfig default (`PCI` evaluates to `n`), and the
  dependency-evaluation sections are meaningless. See "Resolve, then analyze".
- `--since <git-ref|path>` — diff the selector graph against an older tree.
- `--prune-unknown` [`-o FILE`] — delete undefined symbols from the fragment,
  in place or to `-o`.
- `--show-covered` — list every dependent instead of counting them.

Exit status is nonzero when it finds duplicates, ineffective entries, unknown
symbols, broken disables, drift, or unsatisfiable enables, so it works as a CI
gate unmodified.

### Entries that do not take effect

The check for fact 6. It resolves the fragment the way `olddefconfig` would and
compares each line's requested value against what the symbol actually ends up
with, naming the prerequisite that blocked it:

```
  CONFIG_VIRTIO_NET: asked 'y', got 'n'
    unmet dependency (CONFIG_NETDEVICES, CONFIG_NET_CORE)
  CONFIG_HVC_XEN: asked 'y', got 'n'
    unmet dependency (CONFIG_XEN)
```

It also explains disables defeated by a `select` (`forced on by CONFIG_...`)
and `=m` requests that silently became `=y` because `CONFIG_MODULES` is off.
Prompt-less symbols are excluded here and reported under "Entries with no
effect" instead, otherwise they drown the signal — the original aarch64 config
produced 427 findings, of which 141 were merely inert.

**Accuracy depends on the probe environment.** Kconfig shells out for things
like `CONFIG_PAHOLE_VERSION`, and any tool variable left unset probes as
missing, dragging down everything gated on it — `DEBUG_INFO_BTF` was reported
as ineffective until `load_kconfig()` started exporting `PAHOLE`, `NM`,
`OBJCOPY` and friends to match the kernel Makefile. If this section flags
something surprising, check the resolved `.config` before believing it. As of
the last check, all 284 findings on the aarch64 config agreed exactly with
`olddefconfig`.

### Duplicate declarations

Every occurrence is cited as `path:line` with its raw text, and the one that
actually takes effect is marked:

```
Duplicate declarations (2)
--------------------------
The last declaration silently wins. Where the values differ, deleting
the wrong copy or reordering the file changes the resulting kernel.

  CONFIG_DRM  <-- CONFLICT
    configs/x86_64/zone.config:1: CONFIG_DRM=y
    configs/x86_64/zone.config:3: # CONFIG_DRM is not set (wins)
  CONFIG_FOO_BAR
    configs/x86_64/zone.config:2: CONFIG_FOO_BAR=m
    configs/x86_64/zone.config:4: CONFIG_FOO_BAR=m (wins)
```

`CONFLICT` marks a repeat whose values differ — that is the dangerous kind,
because deleting the "wrong" copy changes the kernel. A repeat with the same
value is only noise, but still worth removing. Both syntaxes are matched, so an
enable early in the file and a disable late in it is caught.

### Resolve, then analyze

`--base` wants a *resolved* config, and it must be resolved the way the build
does it — see "Comparing resolved configs". After any build, the file is
already sitting there:

```bash
./hack/build/venv/bin/python hack/build/analyze-fragment.py \
    configs/x86_64/zone.config --srctree ../linux-zone \
    --base obj/linux-6.18.44-x86_64/.config
```

### Tests

```bash
./hack/build/venv/bin/python -m unittest discover -s hack/build -p 'test_*.py' -v
```

23 tests, stdlib `unittest`, no extra dependencies, ~6ms. Run them after any
change to the analyzer — several of its behaviours are subtle enough that a
plausible-looking "simplification" silently breaks them.

`hack/build/test_analyze_fragment.py` splits in three:

- **File operations** — parsing both syntaxes, last-declaration-wins, duplicate
  detection across syntaxes, and that `--prune-unknown` leaves comments and
  blank lines byte-for-byte intact.
- **Graph evaluation** — built against a ~40-line synthetic Kconfig tree in a
  temp directory rather than `../linux-zone`, so the tests are fast, hermetic,
  and can state each tricky construct explicitly.
- **Effectiveness** — requests defeated by a missing prerequisite, by a
  `select`, or by `CONFIG_MODULES` being off.

That synthetic tree deliberately contains a `transitional` property and a bare
`modules` keyword, so if `patch_lexer()` ever stops rewriting the 6.x-only
syntax, the tree fails to load and every graph test errors at once.

Each graph test is a regression test for a bug this script actually had:

| Test | Bug it pins |
|---|---|
| `test_prompted_string_is_assignable` | `is_assignable()` once required BOOL/TRISTATE, misfiling `CONFIG_LOCALVERSION` as inert |
| `test_negated_dependency_is_satisfied_not_broken` | `depends on (AGP \|\| AGP=n)` was read as a dependency on AGP instead of being satisfied by `AGP=n` |
| `test_switchable_excludes_non_boolean_types` | `set_value(0)`/`set_value(2)` must never reach a string symbol |
| `test_duplicate_across_the_two_syntaxes` | an enable and a disable for the same symbol, far apart, is a duplicate |
| `test_request_blocked_by_a_missing_prerequisite` | `CONFIG_NETDEVICES` absent left `VIRTIO_NET=y` resolving to `n`, unreported |
| `test_module_request_without_module_support_becomes_builtin` | `=m` silently coerces to `=y` when `CONFIG_MODULES` is off |

These were checked by mutation: reverting each fix in a scratch copy makes the
corresponding test fail, and only that test.

## Bumping to a new LTS

Run these in order — pruning first keeps noise out of everything after it.

### 0. Confirm the Kconfig parser still works

Each kernel release risks new Kconfig syntax. 6.18 added two bare keywords
(`transitional` in `arch/Kconfig`, `modules` in `kernel/module/Kconfig`) that
`kconfiglib` 14.x does not know. A failure looks like:

```
kconfiglib.KconfigError: <file>:<line>: error: couldn't parse 'foo': syntax error
```

Diff the lexer between tags to see what is new:

```bash
git -C ../linux-zone diff v6.18..<newtag> -- scripts/kconfig/lexer.l
```

If the keyword carries no dependency information, add a rewrite to
`patch_lexer()` in the analyzer next to `_TRANSITIONAL` / `_MODULES`. It
rewrites files as they are read rather than patching the vendored parser.

### 1. Drop symbols the new tree no longer defines

```bash
for c in configs/x86_64/*.config; do
  ./hack/build/venv/bin/python hack/build/analyze-fragment.py "$c" \
      --srctree ../linux-zone --prune-unknown
done
```

Repeat for `configs/aarch64/` with `--arch arm64`.

**Do not prune an arch-shared fragment on one arch alone.** "Undefined" is only
computed for the ARCH you pass, so an arm64-only symbol looks dead on x86_64.

### 2. Find what the new kernel can silently re-enable

```bash
./hack/build/venv/bin/python hack/build/analyze-fragment.py \
    configs/x86_64/zone.config --srctree ../linux-zone --since v6.18
```

This is the step that matters most on a bump. It reports only the
`select`/`imply` edges that are new since the old tag, in two classes:

- **`new symbol`** — a driver landed that selects something you turned off.
- **`new edge`** — an existing symbol *started* selecting it. Watching for new
  config options will never catch this class.

A real example: `FPROBE` was reimplemented on top of the function graph tracer
between 6.12 and 6.18, gaining `select FUNCTION_GRAPH_TRACER`. Nothing about the
symbol was new; a long-standing disable quietly became conditional.

`--since` takes a git ref in `--srctree` (Kconfig files and `scripts/` are
extracted to a temp dir via `git archive`, no worktree needed) or a path to a
second kernel tree.

Then resolve against the new tree and re-run with `--base` to get the remaining
sections — broken disables, inert disables, redundant disables, unsatisfiable
enables — evaluated against real symbol values rather than Kconfig defaults:

```bash
cp configs/x86_64/zone.config ../linux-zone/arch/x86/configs/
mkdir -p /tmp/o && make -C ../linux-zone O=/tmp/o ARCH=x86_64 olddefconfig zone.config

./hack/build/venv/bin/python hack/build/analyze-fragment.py \
    configs/x86_64/zone.config --srctree ../linux-zone \
    --base /tmp/o/.config --since v6.18
```

Repeat per config and per arch:

```bash
for c in configs/x86_64/*.config; do
  echo "### $c"
  ./hack/build/venv/bin/python hack/build/analyze-fragment.py "$c" \
      --srctree ../linux-zone --since v6.18
done
```

### 3. Diff the resolved kernels, old tree vs new

**The analyzer cannot do this part.** It reads the symbol graph, so it finds
symbols appearing, disappearing, and gaining `select` edges. It does *not* find
a symbol whose `default` changed, or one whose behaviour changed while its name
stayed the same. Only resolving both trees and diffing catches those.

Here the *configs* are fixed and the *kernel tree* varies, so check the old tag
out beside the new one:

```bash
K=../linux-zone
git -C $K worktree add /tmp/k-old v6.18       # the LTS you are leaving

for t in old new; do
  tree=$([ $t = old ] && echo /tmp/k-old || echo $K)
  rm -rf /tmp/r-$t && mkdir -p /tmp/r-$t
  cp configs/x86_64/zone.config $tree/arch/x86/configs/
  make -C $tree O=/tmp/r-$t ARCH=x86_64 olddefconfig zone.config
done

diff /tmp/r-old/.config /tmp/r-new/.config | grep -E '^[<>] CONFIG'
git -C $K worktree remove /tmp/k-old
```

For a variant, name both fragments on the make line — see "Comparing resolved
configs" below.

Treat every line in the diff as something you can explain. This is how the AMD
helper closure and an `I2C_ALGOBIT` `y`→`m` change surfaced during the graphics
split; neither was visible in the fragment text.

### 4. Gate it

```bash
analyze-fragment.py configs/x86_64/zone.config --srctree ../linux-zone \
    --since "$PREV_TAG" || fail
```

Run this on the current LTS too, not only at bump time. The `--since` window is
whatever you pass it, so pointing it at the last released tag on every build
turns drift into a caught regression instead of a later discovery.

## Comparing resolved configs

The only way to know what a config edit does to the built kernel. Use it for any
change to `configs/`, not just version bumps.

**Use the build's own method.** `hack/build/common.sh:162` copies the fragment
into `arch/<arch>/configs/` and runs:

```
make -C $KERNEL_SRC O=$KERNEL_OBJ ARCH=$ARCH olddefconfig <flavor>.config [<variant>.fragment.config]
```

That merges the fragment onto a `.config` in which **every unlisted symbol sits
at its Kconfig default**. Treating a flavor config as a complete config instead
— `cp zone.config .config && olddefconfig` — resolves roughly half as many
symbols (2184 vs 4436 for x86_64 `zone`) and, worse, silently omits the drivers
that defeat your disables. `EEEPC_LAPTOP` selecting `HWMON`, and the HID
game-pad drivers selecting `POWER_SUPPLY`, exist only in the real base; against
the wrong baseline the analyzer reports zero broken disables and the build then
ships them anyway.

```bash
R=$PWD
K=/home/alexm/edera/linux-zone
S=$(mktemp -d)

resolve() {            # resolve <outdir> <flavor-config> [variant-fragment]
  local out=$1 flavor=$2 variant=$3
  cp "$flavor" "$K/arch/x86/configs/"
  [ -n "$variant" ] && cp "$variant" "$K/arch/x86/configs/"
  rm -rf "$out" && mkdir -p "$out"
  make -C "$K" O="$out" ARCH=x86_64 olddefconfig \
      "$(basename "$flavor")" ${variant:+"$(basename "$variant")"}
}

git show HEAD:configs/x86_64/zone.config > $S/zone.before.config
resolve $S/before $S/zone.before.config
resolve $S/after  $R/configs/x86_64/zone.config

diff $S/before/.config $S/after/.config | grep -E '^[<>] CONFIG' || echo IDENTICAL
```

Feed the result back to the analyzer as `--base`; that is the only baseline its
`select`-override and effectiveness checks can be trusted against:

```bash
./hack/build/venv/bin/python hack/build/analyze-fragment.py \
    configs/x86_64/zone.config --srctree ../linux-zone --base $S/after/.config
```

If a build already ran, `obj/linux-<ver>-<arch>/.config` is exactly this file
and can be used directly.

Notes:

- **Filter to `^[<>] CONFIG`.** The header comment block always differs by
  timestamp and buries the real changes.
- **The fragment must live in `arch/<arch>/configs/`.** The `%.config` make
  target only finds it there; that is why `resolve()` copies it in.
- To count the size of a change:
  `grep -cE '^CONFIG_' $S/before/.config $S/after/.config`
- A variant is resolved by naming both fragments on the same make line, base
  first: `olddefconfig zone.config zone-amdgpu.fragment.config`.
- This resolves a config file on its own. Per `configs/README.md` the real build
  may layer fragments over an upstream defconfig, so use this to **compare**
  before and after, which is what it is for — not as a byte-exact prediction of
  the shipped config.

### The footgun, if you call merge_config.sh directly

The `%.config` make target above uses `merge_config.sh` internally, so you do
not normally invoke it yourself. If you do, note that it does not fail when the
base file is missing:

```sh
if [ ! -r "$INITFILE" ]; then
	echo "The base file '$INITFILE' does not exist. Creating one..." >&2
	touch "$INITFILE"
fi
```

It creates an empty base and merges onto that, producing a defconfig-shaped
result rather than an error. Use absolute paths for every config argument, and
**do not discard stderr**. If a diff looks implausibly large, check its output
for `Creating one...` before believing the result.

## Config layout conventions

### Graphics belongs in the GPU variants

`zone.config` explicitly disables the graphics stack. Only `zone-amdgpu` and
`zone-nvidiagpu` re-enable it. The base carries:

```
# CONFIG_ACPI_VIDEO is not set
# CONFIG_AGP is not set
# CONFIG_BACKLIGHT_CLASS_DEVICE is not set
# CONFIG_DRM is not set
# CONFIG_FB is not set
# CONFIG_VGA_CONSOLE is not set
```

plus `# CONFIG_VGA_ARB is not set`, which stays in the PCI section where the
symbol belongs rather than moving into the graphics block.

Only *prompted* symbols are listed. The helper symbols beneath them have no
prompt (fact 2) and follow automatically. Zones get their console over
serial/hvc/virtio-console, not a framebuffer.

Two graphics-adjacent symbols stay on and cannot be disabled from a config file:

- `I2C_ALGOBIT` — selected by `IGB`, the Intel NIC driver, which bit-bangs i2c
  for SFP modules. Nothing to do with graphics.
- `FONT_SUPPORT` / `FONT_8x16` — selected by `EFI_EARLYCON`. Font data for the
  early console.

### When a variant declares nothing, it inherits

A variant that relies on the base for a symbol will silently lose it the day
that symbol leaves the base. Both GPU variants were inheriting AMD sub-options
they never declared. If a variant needs a symbol, it should say so, even if the
base currently provides it.

## Known limitations

- **Per-arch only.** Every result is computed for one ARCH. Run each arch
  separately; `--prune-unknown` is destructive and arch-blind.
- **Graph, not behaviour.** The analyzer answers questions about the Kconfig
  dependency graph. It says nothing about whether the resulting kernel boots or
  whether a driver still works.
- **`--base` matters.** The dependency-evaluation sections need a real resolved
  config as a baseline. Without one the tool falls back to the fragment itself,
  which is honest but coarser.
- **Default changes are invisible to it.** Step 3 exists for this reason.
- **`kconfiglib` lags the kernel.** Expect to extend `patch_lexer()` roughly
  once per release cycle.
