#!/usr/bin/env python3
"""Analyze a kconfig fragment against a kernel tree's Kconfig dependency graph.

Answers three questions about a fragment before you spend a build on it:

  1. Which disables will not hold, because some other symbol `select`s them.
     `select` ignores `depends on`, so a `# CONFIG_X is not set` line loses
     silently if any reachable symbol selects X.

  2. Which entries are redundant, because another entry in the same fragment
     already implies them through `depends on` or menu nesting. These are the
     lines you can delete and let `olddefconfig` re-derive.

  3. What each disable actually takes down, so you can judge whether one
     high-level line covers the subtree you meant.

With `--base .config` the selector states are resolved against a real config,
so "at risk" narrows to "actually on". Without it, every selector is reported.

With `--since <git-ref|path>` the report gains a version-bump section: only the
selectors that did not exist, or did not select the target, in the older tree.
That is the drift check for a kernel upgrade -- a disable that held on 6.12 can
be quietly reverted by a symbol introduced in 6.18.

Usage:
    analyze-fragment.py configs/x86_64/zone.config --srctree ../linux-zone
    analyze-fragment.py fragment.config --srctree ../linux-zone --arch arm64
    analyze-fragment.py fragment.config --srctree ../linux-zone --base obj/.config
    analyze-fragment.py fragment.config --srctree ../linux-zone --since v6.12

`--prune-unknown` deletes the lines for symbols the tree no longer defines,
rewriting the fragment in place (or to `--output`). Only the requested ARCH is
checked, so do not prune an arch-shared fragment on one arch alone.
"""

import argparse
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import kconfiglib
except ModuleNotFoundError:
    sys.exit("kconfiglib is required: pip install kconfiglib")


# kconfiglib 14.x predates two bare Kconfig keywords that 6.x kernels use.
# Neither carries dependency information, so rewrite them as the files are read
# rather than patching the vendored parser.
_TRANSITIONAL = re.compile(r"^\s*transitional\s*$")
_MODULES = re.compile(r"^(\s*)modules\s*$")

_SET = re.compile(r"^(CONFIG_[A-Za-z0-9_]+)=(.+)$")
_UNSET = re.compile(r"^#\s*(CONFIG_[A-Za-z0-9_]+) is not set\s*$")

_SRCARCH = {"x86_64": "x86", "i386": "x86", "x86": "x86", "aarch64": "arm64"}


def patch_lexer() -> None:
    original = kconfiglib.Kconfig._open

    def rewrite(line: str) -> str:
        if _TRANSITIONAL.match(line):
            return ""
        match = _MODULES.match(line)
        return f"{match.group(1)}option modules\n" if match else line

    def _open(self, filename, mode):
        handle = original(self, filename, mode)
        if "r" not in mode:
            return handle
        with handle:
            return io.StringIO("".join(rewrite(line) for line in handle))

    kconfiglib.Kconfig._open = _open


def kernel_version(srctree: Path) -> str:
    fields = {}
    for line in (srctree / "Makefile").read_text().splitlines()[:10]:
        key, _, value = line.partition(" = ")
        if key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
            fields[key] = value.strip()
    return "{}.{}.{}".format(
        fields.get("VERSION", "6"),
        fields.get("PATCHLEVEL", "0"),
        fields.get("SUBLEVEL", "0"),
    )


def load_kconfig(srctree: Path, arch: str) -> kconfiglib.Kconfig:
    os.environ.update(
        srctree=str(srctree),
        ARCH=arch,
        SRCARCH=_SRCARCH.get(arch, arch),
        KERNELVERSION=kernel_version(srctree),
        CC="gcc",
        LD="ld",
        RUSTC="rustc",
        HOSTCC="gcc",
        HOSTCXX="g++",
        CC_VERSION_TEXT="gcc",
    )
    cwd = os.getcwd()
    os.chdir(srctree)
    try:
        return kconfiglib.Kconfig("Kconfig", warn=False)
    finally:
        os.chdir(cwd)


def resolve_since(srctree: Path, since: str) -> tuple[Path, str, Path | None]:
    """Return (tree, label, tempdir) for the comparison point.

    `since` is either a directory holding a second kernel tree, or a git ref in
    `srctree`. For a ref, the Kconfig files and scripts/ are extracted to a temp
    directory -- enough for the symbol graph, far cheaper than a full checkout.
    """
    candidate = Path(since)
    if candidate.is_dir():
        return candidate.resolve(), str(candidate), None

    tmp = Path(tempfile.mkdtemp(prefix="analyze-fragment-"))
    archive = subprocess.run(
        [
            "git",
            "-C",
            str(srctree),
            "archive",
            since,
            "--",
            "*Kconfig*",
            "Makefile",
            "scripts",
        ],
        capture_output=True,
    )
    if archive.returncode:
        shutil.rmtree(tmp, ignore_errors=True)
        sys.exit(f"cannot resolve --since {since!r}: {archive.stderr.decode().strip()}")
    subprocess.run(["tar", "-x", "-C", str(tmp)], input=archive.stdout, check=True)
    return tmp, since, tmp


def prune_symbols(path: Path, names: set[str], output: Path) -> list[str]:
    """Drop every line defining one of `names`, leaving all other bytes untouched."""
    kept: list[str] = []
    removed: list[str] = []
    for line in path.read_text().splitlines(keepends=True):
        match = _UNSET.match(line) or _SET.match(line)
        if match and match.group(1)[len("CONFIG_") :] in names:
            removed.append(line.rstrip("\n"))
        else:
            kept.append(line)
    output.write_text("".join(kept))
    return removed


def select_edges(kconf: kconfiglib.Kconfig) -> dict[str, set[tuple[str, str]]]:
    """Map target symbol name -> {(selector name, "select"|"imply")}."""
    edges: dict[str, set[tuple[str, str]]] = {}
    for sym in kconf.unique_defined_syms:
        for target, _ in sym.selects:
            edges.setdefault(target.name, set()).add((sym.name, "select"))
        for target, _ in sym.implies:
            edges.setdefault(target.name, set()).add((sym.name, "imply"))
    return edges


def parse_fragment(path: Path) -> tuple[dict[str, str], list[str]]:
    """Return {symbol: value} where value is "n" for `is not set`, plus order."""
    values: dict[str, str] = {}
    order: list[str] = []
    for line in path.read_text().splitlines():
        match = _UNSET.match(line) or _SET.match(line)
        if not match:
            continue
        name = match.group(1)[len("CONFIG_") :]
        if name not in values:
            order.append(name)
        values[name] = "n" if match.re is _UNSET else match.group(2)
    return values, order


def find_duplicates(path: Path) -> dict[str, list[tuple[int, str, str]]]:
    """Symbols declared more than once, as {name: [(lineno, value, raw line)]}.

    The last declaration silently wins. A repeat with differing values is a
    latent bug: reordering the file, or deleting the "wrong" copy, changes the
    resulting kernel with nothing to warn you.
    """
    seen: dict[str, list[tuple[int, str, str]]] = {}
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        match = _UNSET.match(line) or _SET.match(line)
        if not match:
            continue
        name = match.group(1)[len("CONFIG_") :]
        value = "n" if match.re is _UNSET else match.group(2)
        seen.setdefault(name, []).append((lineno, value, line.strip()))
    return {name: occ for name, occ in seen.items() if len(occ) > 1}


def depend_index(kconf: kconfiglib.Kconfig) -> dict[str, list[str]]:
    """Map symbol name -> names of symbols whose direct_dep references it."""
    depended_on_by: dict[str, list[str]] = {}
    for sym in kconf.unique_defined_syms:
        for item in kconfiglib.expr_items(sym.direct_dep):
            if isinstance(item, kconfiglib.Symbol) and item.name:
                depended_on_by.setdefault(item.name, []).append(sym.name)
    return depended_on_by


def is_assignable(sym: kconfiglib.Symbol) -> bool:
    """True if a config file can actually set this symbol.

    Symbols with no prompt take their value from `select`/`default` alone, so a
    config line naming one is inert. Applies to every type, not just bool and
    tristate -- CONFIG_LOCALVERSION is a prompted string and very much settable.
    """
    return any(node.prompt for node in sym.nodes)


def is_switchable(sym: kconfiglib.Symbol) -> bool:
    """Assignable *and* bool/tristate, so set_value(0)/set_value(2) is meaningful."""
    return is_assignable(sym) and sym.orig_type in (kconfiglib.BOOL, kconfiglib.TRISTATE)


def apply_disables(kconf: kconfiglib.Kconfig, disabled: set[str]) -> None:
    """Force the fragment's disabled symbols to n so dependencies can be evaluated."""
    for name in disabled:
        sym = kconf.syms.get(name)
        if sym and sym.nodes and is_switchable(sym):
            sym.set_value(0)


def blocked_by(
    kconf: kconfiglib.Kconfig, sym: kconfiglib.Symbol, disabled: set[str]
) -> list[str]:
    """Which disabled symbols actually falsify `sym`'s dependency?

    Evaluates the expression rather than testing membership, so `depends on
    (AGP || AGP=n)` is correctly *satisfied* by AGP=n instead of being read as a
    dependency on AGP. Returns [] when the dependency still holds.
    """
    if kconfiglib.expr_value(sym.direct_dep) != 0:
        return []

    causes = []
    for item in kconfiglib.expr_items(sym.direct_dep):
        if not isinstance(item, kconfiglib.Symbol) or item is sym:
            continue
        if item.name not in disabled or not item.nodes or not is_switchable(item):
            continue
        item.set_value(2)  # pretend this one is on
        recovered = kconfiglib.expr_value(sym.direct_dep) != 0
        item.set_value(0)
        if recovered:
            causes.append(item.name)
    return sorted(causes)


def menu_path(sym: kconfiglib.Symbol) -> str:
    if not sym.nodes:
        return "<no menu node>"
    parts = []
    node = sym.nodes[0].parent
    while node and node is not node.kconfig.top_node:
        if node.prompt:
            parts.append(node.prompt[0])
        node = node.parent
    return " > ".join(reversed(parts)) or "<top level>"


def section(title: str) -> None:
    print(f"\n{title}\n{'-' * len(title)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("fragment", type=Path, help="kconfig fragment to analyze")
    parser.add_argument(
        "--srctree", type=Path, required=True, help="kernel source tree"
    )
    parser.add_argument("--arch", default="x86_64", help="ARCH (default: x86_64)")
    parser.add_argument(
        "--base", type=Path, help="resolved .config to evaluate selectors against"
    )
    parser.add_argument(
        "--since", help="git ref or second tree to diff the selector graph against"
    )
    parser.add_argument(
        "--show-covered",
        action="store_true",
        help="list every symbol each disable takes down",
    )
    parser.add_argument(
        "--prune-unknown",
        action="store_true",
        help="delete undefined symbols from the fragment",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="write the pruned fragment here instead of in place",
    )
    args = parser.parse_args()

    patch_lexer()
    srctree = args.srctree.resolve()
    kconf = load_kconfig(srctree, args.arch)
    edges = select_edges(kconf)
    depended_on_by = depend_index(kconf)
    defined = {sym.name for sym in kconf.unique_defined_syms}

    old_edges: dict[str, set[tuple[str, str]]] = {}
    old_defined: set[str] = set()
    since_label = ""
    if args.since:
        old_tree, since_label, tmp = resolve_since(srctree, args.since)
        try:
            old = load_kconfig(old_tree, args.arch)
            old_edges = select_edges(old)
            old_defined = {sym.name for sym in old.unique_defined_syms}
        finally:
            if tmp:
                shutil.rmtree(tmp, ignore_errors=True)

    # Evaluation baseline for the dependency checks below. Without loading a
    # config, every symbol sits at its Kconfig default -- PCI reads as n, and
    # `depends on DRM && PCI` is false for reasons that have nothing to do with
    # the fragment. The fragment itself is the minimum honest baseline; --base
    # layers it on a fuller .config for a sharper answer.
    if args.base:
        kconf.load_config(str(args.base.resolve()))
        kconf.load_config(str(args.fragment.resolve()), replace=False)
    else:
        kconf.load_config(str(args.fragment.resolve()))

    values, order = parse_fragment(args.fragment)
    selected_by = {name: sorted(pairs) for name, pairs in edges.items()}

    disabled = {n for n, v in values.items() if v == "n"}
    enabled = {n for n, v in values.items() if v != "n"}
    unknown = [n for n in order if n not in kconf.syms or not kconf.syms[n].nodes]

    print(f"fragment: {args.fragment}")
    print(
        f"tree:     {args.srctree} (ARCH={args.arch}, {kernel_version(args.srctree.resolve())})"
    )
    print(f"entries:  {len(enabled)} enabled, {len(disabled)} disabled")

    # Declared more than once. Reported first: it is a property of the file
    # itself, and a conflicting repeat makes every later section suspect.
    duplicates = find_duplicates(args.fragment)
    conflicting = [n for n, occ in duplicates.items() if len({v for _, v, _ in occ}) > 1]

    section(f"Duplicate declarations ({len(duplicates)})")
    if not duplicates:
        print("None. Every symbol is declared exactly once.")
    else:
        print("The last declaration silently wins. Where the values differ, deleting")
        print("the wrong copy or reordering the file changes the resulting kernel.\n")
        for name in sorted(duplicates):
            occurrences = duplicates[name]
            flag = "  <-- CONFLICT" if name in conflicting else ""
            print(f"  CONFIG_{name}{flag}")
            for index, (lineno, _, raw) in enumerate(occurrences):
                wins = " (wins)" if index == len(occurrences) - 1 else ""
                print(f"    {args.fragment}:{lineno}: {raw}{wins}")

    pruned = False
    if unknown:
        section(f"Unknown symbols ({len(unknown)})")
        print(
            f"Not defined for ARCH={args.arch} — a typo, a dropped symbol, or another arch's option."
        )
        if not args.prune_unknown:
            for name in unknown:
                print(f"  CONFIG_{name}")
            print("\nRe-run with --prune-unknown to delete these lines.")
        else:
            destination = args.output or args.fragment
            removed = prune_symbols(args.fragment, set(unknown), destination)
            for line in removed:
                print(f"  - {line}")
            print(f"\nremoved {len(removed)} line(s) -> {destination}")
            print(
                f"Verify against every ARCH this fragment feeds; only {args.arch} was checked."
            )
            pruned = True

    # 1. Disables that select can override.
    broken = []
    for name in sorted(disabled):
        selectors = selected_by.get(name, [])
        if not selectors:
            continue
        risky = []
        for selector, kind in selectors:
            if selector in disabled:
                continue  # the fragment turns the selector off too
            if args.base and kconf.syms[selector].str_value == "n":
                continue  # not on in the resolved base config
            risky.append((selector, kind))
        if risky:
            broken.append((name, risky))

    section(f"Disables that `select` can override ({len(broken)})")
    if not broken:
        print("None. Every disabled symbol is free of live reverse dependencies.")
    else:
        scope = "enabled in --base" if args.base else "not disabled by this fragment"
        print(f"These symbols are selected by others that are {scope}.")
        print(
            "`select` ignores `depends on`, so these lines can be silently reverted.\n"
        )
        for name, risky in broken:
            hard = [s for s, _ in risky if s in enabled]
            flag = (
                "  <-- CONTRADICTION: selector is enabled by this fragment"
                if hard
                else ""
            )
            print(f"  CONFIG_{name}: {len(risky)} live selector(s){flag}")
            for selector, kind in risky[:8]:
                mark = "*" if selector in enabled else " "
                print(f"    {mark} {kind} by CONFIG_{selector}")
            if len(risky) > 8:
                print(f"      ... and {len(risky) - 8} more")

    # 1b. Selector edges that appeared since the comparison tree.
    drift = []
    if args.since:
        for name in sorted(disabled):
            new_edges = sorted(edges.get(name, set()) - old_edges.get(name, set()))
            new_edges = [(s, k) for s, k in new_edges if s not in disabled]
            if new_edges:
                drift.append((name, new_edges))

        section(f"New selectors since {since_label} ({len(drift)})")
        if not drift:
            print(
                f"None. No symbol gained a select/imply edge into a disabled symbol since {since_label}."
            )
        else:
            print("Each of these can revert a disable that held on the older kernel.")
            print(
                "`new symbol` did not exist before; `new edge` existed but did not select this.\n"
            )
            for name, new_edges in drift:
                print(f"  CONFIG_{name}: {len(new_edges)} new selector(s)")
                for selector, kind in new_edges:
                    origin = "new symbol" if selector not in old_defined else "new edge"
                    print(f"      {kind} by CONFIG_{selector}  ({origin})")

    # From here on, dependencies are evaluated with the fragment's disables applied.
    apply_disables(kconf, disabled)

    # 2a. Disables that cannot do anything, because the symbol has no prompt.
    inert = [
        n
        for n in sorted(disabled)
        if (sym := kconf.syms.get(n)) and sym.nodes and not is_assignable(sym)
    ]

    section(f"Disables with no effect ({len(inert)})")
    if not inert:
        print("None. Every disabled symbol is settable from a config file.")
    else:
        print(
            "These symbols have no prompt, so their value comes from `select`/`default`"
        )
        print("alone and a config-file line cannot change it. Delete them.\n")
        for name in inert:
            print(f"  CONFIG_{name}")

    # 2b. Entries another fragment entry already forces off.
    redundant = []
    for name in sorted(disabled):
        sym = kconf.syms.get(name)
        if not sym or not sym.nodes:
            continue
        causes = blocked_by(kconf, sym, disabled)
        if causes:
            redundant.append((name, causes))

    section(f"Redundant disables ({len(redundant)})")
    if not redundant:
        print("None. Every disabled symbol is independently reachable.")
    else:
        print(
            "Their dependency evaluates false once the other disables are applied, so"
        )
        print(
            "olddefconfig turns them off regardless. Safe to delete from the fragment.\n"
        )
        for name, causes in redundant:
            print(
                f"  CONFIG_{name}  <- forced off by {', '.join('CONFIG_' + c for c in causes)}"
            )

    # 3. Enabled entries that cannot be satisfied.
    unsatisfiable = []
    for name in sorted(enabled):
        sym = kconf.syms.get(name)
        if not sym or not sym.nodes:
            continue
        blockers = blocked_by(kconf, sym, disabled)
        if blockers:
            unsatisfiable.append((name, blockers))

    section(f"Enabled entries with disabled dependencies ({len(unsatisfiable)})")
    if not unsatisfiable:
        print("None.")
    else:
        print(
            "These are requested on but depend on something this fragment turns off.\n"
        )
        for name, blockers in unsatisfiable:
            print(
                f"  CONFIG_{name}  needs {', '.join('CONFIG_' + b for b in blockers)}"
            )

    # 4. Reach of each disable.
    section("Reach of each disable")
    print("How many symbols each line takes down through `depends on` (direct only).\n")
    for name in sorted(disabled, key=lambda n: -len(depended_on_by.get(n, []))):
        dependents = sorted(set(depended_on_by.get(name, [])))
        sym = kconf.syms.get(name)
        where = menu_path(sym) if sym and sym.nodes else "<unknown>"
        print(f"  CONFIG_{name}: {len(dependents)} dependent(s)   [{where}]")
        if args.show_covered and dependents:
            for dep in dependents:
                print(f"      CONFIG_{dep}")

    return (
        1
        if duplicates or broken or drift or unsatisfiable or (unknown and not pruned)
        else 0
    )


if __name__ == "__main__":
    sys.exit(main())
