#!/usr/bin/env python3
"""Gate a resolved kernel .config against explicit zone criteria.

Three checks, all of which fail the build on violation:

  1. stickiness  - every symbol a fragment requests resolves to that value
  2. required    - every symbol in a required manifest is =y or =m
  3. forbidden   - every symbol in a forbidden manifest is absent or 'n'

Symbols listed in a whitelist are exempt from the stickiness and forbidden checks:
patched-in symbols (absent from a vanilla tree) or toolchain-gated symbols
(DEBUG_INFO_BTF needs pahole, GCC_PLUGINS needs plugin headers) that can legitimately
not resolve in a given tree.

This must run against the fully-resolved .config of the patched tree with the real
toolchain, i.e. after `make olddefconfig` in prepare.sh, so those symbols resolve.

Usage:
  verify-config.py --config <.config> [--whitelist <f>]
      [--fragment <f> ...] [--required <f> ...] [--forbidden <f> ...]
"""

import argparse
import re
import sys

SET = re.compile(r"^(CONFIG_[A-Za-z0-9_]+)=(.*)$")
NOTSET = re.compile(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$")


def parse_config(path: str) -> dict[str, str]:
    """Parse a .config or fragment into {symbol: value}; 'n' for 'is not set'."""
    values: dict[str, str] = {}
    with open(path) as handle:
        for line in handle:
            line = line.rstrip("\n")
            match = SET.match(line)
            if match:
                values[match.group(1)] = match.group(2)
                continue
            match = NOTSET.match(line)
            if match:
                values[match.group(1)] = "n"
    return values


def parse_list(path: str) -> list[str]:
    """Read a manifest of one CONFIG symbol per line; ignore blanks and comments."""
    out: list[str] = []
    with open(path) as handle:
        for line in handle:
            token = line.strip()
            if token and not token.startswith("#"):
                out.append(token.split("=")[0] if "=" in token else token)
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--whitelist")
    parser.add_argument("--fragment", action="append", default=[])
    parser.add_argument("--required", action="append", default=[])
    parser.add_argument("--forbidden", action="append", default=[])
    args = parser.parse_args()

    resolved = parse_config(args.config)
    whitelist = set(parse_list(args.whitelist)) if args.whitelist else set()
    fails: list[str] = []

    for fragment in args.fragment:
        for symbol, want in parse_config(fragment).items():
            if symbol in whitelist:
                continue
            have = resolved.get(symbol)  # None: absent (off / unmet deps / unknown)
            if want in ("y", "m") and (have is None or have == "n"):
                fails.append(
                    f"STICK  {symbol}: asked {want}, resolved {have or 'ABSENT'}"
                )
            elif want == "n" and have in ("y", "m"):
                fails.append(f"STICK  {symbol}: asked n, resolved {have}")
            elif want not in ("y", "m", "n") and have is not None and have != want:
                fails.append(f"STICK  {symbol}: asked {want}, resolved {have}")

    for manifest in args.required:
        for symbol in parse_list(manifest):
            if resolved.get(symbol) not in ("y", "m"):
                got = resolved.get(symbol) or "ABSENT"
                fails.append(f"REQ    {symbol}: must be y/m, resolved {got}")

    for manifest in args.forbidden:
        for symbol in parse_list(manifest):
            if symbol not in whitelist and resolved.get(symbol) in ("y", "m"):
                fails.append(
                    f"FORBID {symbol}: must be off, resolved {resolved[symbol]}"
                )

    if fails:
        print(f"verify-config: FAIL ({len(fails)} violations):", file=sys.stderr)
        for fail in sorted(fails):
            print("  " + fail, file=sys.stderr)
        sys.exit(1)
    print("verify-config: PASS")


if __name__ == "__main__":
    main()
