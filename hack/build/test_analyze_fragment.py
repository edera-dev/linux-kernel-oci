#!/usr/bin/env python3
"""Unit tests for analyze-fragment.py.

Run with:
    ./hack/build/venv/bin/python -m unittest discover -s hack/build -p 'test_*.py' -v

The graph tests build a tiny synthetic Kconfig tree in a temp directory rather
than loading ../linux-zone. That keeps them fast and hermetic, and it lets each
tricky construct -- a negated dependency, a prompt-less symbol, a prompted
string, the 6.x-only keywords -- be expressed in a few lines and asserted on
directly.

Every graph case here is a regression test for a bug this script actually had.
"""

import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_analyzer():
    """Import analyze-fragment.py, whose hyphen makes it un-importable normally."""
    spec = importlib.util.spec_from_file_location(
        "analyze_fragment", HERE / "analyze-fragment.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


af = load_analyzer()


# A `transitional` property and a bare `modules` keyword: both are 6.x-only
# Kconfig syntax that kconfiglib 14.x cannot parse. If patch_lexer() ever stops
# rewriting them, this tree fails to load and every graph test below errors.
KCONFIG = """\
mainmenu "Analyzer test tree"

config MODULES
\tbool "Enable loadable module support"
\tmodules

config AGP
\tbool "AGP support"

config DRM
\tbool "Direct Rendering Manager"
\tdepends on (AGP || AGP=n)

config DRM_HELPER
\ttristate
\tdepends on DRM

config DRM_DRIVER
\ttristate "A DRM driver"
\tdepends on DRM
\tselect DRM_HELPER

config BACKLIGHT
\tbool "Backlight class device"

config LAPTOP_THING
\tbool "Some laptop widget"
\tselect BACKLIGHT

config LOCALVERSION
\tstring "Local version string"
\tdefault ""

config RENAMED_AWAY
\tbool
\ttransitional
"""

MAKEFILE = "VERSION = 6\nPATCHLEVEL = 18\nSUBLEVEL = 23\nNAME = Test\n"


class FragmentFileTests(unittest.TestCase):
    """Parsing, duplicate detection and pruning: pure file operations."""

    def write(self, text: str) -> Path:
        path = Path(self.tmp.name) / "fragment.config"
        path.write_text(text)
        return path

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_parse_reads_both_syntaxes(self):
        path = self.write("CONFIG_A=y\n# CONFIG_B is not set\nCONFIG_C=\"str\"\n")
        values, order = af.parse_fragment(path)
        self.assertEqual(values, {"A": "y", "B": "n", "C": '"str"'})
        self.assertEqual(order, ["A", "B", "C"])

    def test_parse_ignores_comments_and_blanks(self):
        path = self.write("# a note\n\nCONFIG_A=y\n#\n# CONFIG_B is unrelated text\n")
        values, _ = af.parse_fragment(path)
        self.assertEqual(values, {"A": "y"})

    def test_parse_last_declaration_wins(self):
        path = self.write("CONFIG_A=m\nCONFIG_A=y\n")
        values, order = af.parse_fragment(path)
        self.assertEqual(values["A"], "y")
        self.assertEqual(order, ["A"], "a repeated symbol should appear once in order")

    def test_no_duplicates_in_a_clean_file(self):
        path = self.write("CONFIG_A=y\nCONFIG_B=m\n# CONFIG_C is not set\n")
        self.assertEqual(af.find_duplicates(path), {})

    def test_duplicate_across_the_two_syntaxes(self):
        # The HWMON/POWER_SUPPLY shape: an enable early, a disable later.
        path = self.write("CONFIG_HWMON=y\nCONFIG_OTHER=y\n# CONFIG_HWMON is not set\n")
        duplicates = af.find_duplicates(path)
        self.assertEqual(list(duplicates), ["HWMON"])
        occurrences = duplicates["HWMON"]
        self.assertEqual([line for line, _, _ in occurrences], [1, 3])
        self.assertEqual([value for _, value, _ in occurrences], ["y", "n"])

    def test_duplicate_reports_occurrences_in_file_order(self):
        # The I40E shape: =m first, =y later, so the later one silently wins.
        path = self.write("CONFIG_I40E=m\nCONFIG_X=y\nCONFIG_I40E=y\n")
        occurrences = af.find_duplicates(path)["I40E"]
        self.assertEqual(occurrences[-1][1], "y", "last occurrence is the winner")
        self.assertEqual(occurrences[0][2], "CONFIG_I40E=m", "raw text is preserved")

    def test_prune_removes_only_named_symbols(self):
        path = self.write("# keep me\nCONFIG_A=y\n\nCONFIG_B=m\n# CONFIG_C is not set\n")
        out = Path(self.tmp.name) / "out.config"
        removed = af.prune_symbols(path, {"B", "C"}, out)
        self.assertEqual(removed, ["CONFIG_B=m", "# CONFIG_C is not set"])
        self.assertEqual(
            out.read_text(),
            "# keep me\nCONFIG_A=y\n\n",
            "comments and blank lines must survive untouched",
        )

    def test_prune_is_a_no_op_for_unmatched_names(self):
        original = "CONFIG_A=y\nCONFIG_B=m\n"
        path = self.write(original)
        out = Path(self.tmp.name) / "out.config"
        self.assertEqual(af.prune_symbols(path, {"NOPE"}, out), [])
        self.assertEqual(out.read_text(), original)


class KconfigGraphTests(unittest.TestCase):
    """Dependency evaluation against a real (tiny) Kconfig graph."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        tree = Path(cls.tmp.name)
        (tree / "Kconfig").write_text(KCONFIG)
        (tree / "Makefile").write_text(MAKEFILE)
        af.patch_lexer()
        cls.tree = tree
        cls.kconf = af.load_kconfig(tree, "x86_64")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def sym(self, name):
        return self.kconf.syms[name]

    def test_tree_loads_despite_6x_only_keywords(self):
        # Proves patch_lexer() handled `modules` and `transitional`.
        self.assertIn("RENAMED_AWAY", self.kconf.syms)
        self.assertIn("MODULES", self.kconf.syms)

    def test_kernel_version_is_read_from_the_makefile(self):
        self.assertEqual(af.kernel_version(self.tree), "6.18.23")

    def test_prompted_string_is_assignable(self):
        # Regression: is_assignable() once required BOOL/TRISTATE, which
        # misfiled CONFIG_LOCALVERSION as inert and would have deleted it.
        self.assertTrue(af.is_assignable(self.sym("LOCALVERSION")))

    def test_promptless_symbol_is_not_assignable(self):
        self.assertFalse(af.is_assignable(self.sym("DRM_HELPER")))

    def test_switchable_excludes_non_boolean_types(self):
        # is_switchable gates set_value(0)/set_value(2); a string is assignable
        # but must never be handed a tristate value.
        self.assertTrue(af.is_switchable(self.sym("DRM")))
        self.assertFalse(af.is_switchable(self.sym("LOCALVERSION")))
        self.assertFalse(af.is_switchable(self.sym("DRM_HELPER")))

    def test_select_edges_records_selector_and_kind(self):
        edges = af.select_edges(self.kconf)
        self.assertIn(("DRM_DRIVER", "select"), edges["DRM_HELPER"])
        self.assertIn(("LAPTOP_THING", "select"), edges["BACKLIGHT"])
        self.assertNotIn("DRM", edges, "nothing selects DRM in this tree")

    def test_negated_dependency_is_satisfied_not_broken(self):
        # Regression: `depends on (AGP || AGP=n)` is SATISFIED when AGP is off.
        # The old membership test saw AGP in the expression and wrongly called
        # DRM redundant.
        disabled = {"AGP", "DRM"}
        af.apply_disables(self.kconf, disabled)
        self.assertEqual(af.blocked_by(self.kconf, self.sym("DRM"), disabled), [])

    def test_real_dependency_is_attributed_to_the_right_symbol(self):
        disabled = {"DRM"}
        af.apply_disables(self.kconf, disabled)
        self.assertEqual(
            af.blocked_by(self.kconf, self.sym("DRM_DRIVER"), disabled), ["DRM"]
        )

    def test_satisfied_dependency_reports_nothing(self):
        af.apply_disables(self.kconf, set())
        self.sym("DRM").set_value(2)
        self.assertEqual(af.blocked_by(self.kconf, self.sym("DRM_DRIVER"), set()), [])


class EffectivenessTests(unittest.TestCase):
    """A line can ask for a value and silently not get it.

    This is the failure that hid CONFIG_NETDEVICES and CONFIG_XEN in the
    aarch64 zone config: symbols requested `=y` that resolved to `n` because a
    prerequisite was never enabled. Its own Kconfig load, so the mutations the
    graph tests perform cannot leak in.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        tree = Path(self.tmp.name)
        (tree / "Kconfig").write_text(KCONFIG)
        (tree / "Makefile").write_text(MAKEFILE)
        af.patch_lexer()
        self.kconf = af.load_kconfig(tree, "x86_64")

    def load(self, text: str):
        path = Path(self.tmp.name) / "frag.config"
        path.write_text(text)
        self.kconf.load_config(str(path))
        return af.parse_fragment(path)

    def test_quotes_are_stripped_for_comparison(self):
        # kconfiglib reports string symbols unquoted.
        self.assertEqual(af.requested_value('"fbdev"'), "fbdev")
        self.assertEqual(af.requested_value("y"), "y")
        self.assertEqual(af.requested_value('""'), "")

    def test_request_blocked_by_a_missing_prerequisite(self):
        values, _ = self.load("CONFIG_DRM_DRIVER=m\n")
        sym = self.kconf.syms["DRM_DRIVER"]
        self.assertEqual(af.requested_value(values["DRM_DRIVER"]), "m")
        self.assertEqual(sym.str_value, "n", "DRM is off, so the driver cannot be on")
        self.assertIn("DRM", af.unmet_in(sym))
        self.assertIn("CONFIG_DRM", af.explain_ineffective(sym, "m", "n"))

    def test_request_that_is_honoured_is_not_flagged(self):
        values, _ = self.load("CONFIG_MODULES=y\nCONFIG_DRM=y\nCONFIG_DRM_DRIVER=m\n")
        sym = self.kconf.syms["DRM_DRIVER"]
        self.assertEqual(sym.str_value, af.requested_value(values["DRM_DRIVER"]))

    def test_module_request_without_module_support_becomes_builtin(self):
        # `=m` is silently coerced to `=y` when CONFIG_MODULES is off. Whole
        # driver sets can land in vmlinux this way while the config still
        # reads `=m`.
        values, _ = self.load("CONFIG_DRM=y\nCONFIG_DRM_DRIVER=m\n")
        sym = self.kconf.syms["DRM_DRIVER"]
        self.assertEqual(af.requested_value(values["DRM_DRIVER"]), "m")
        self.assertEqual(sym.str_value, "y")

    def test_disable_defeated_by_a_select_is_explained(self):
        # LAPTOP_THING selects BACKLIGHT, so disabling BACKLIGHT cannot hold.
        self.load("CONFIG_LAPTOP_THING=y\n# CONFIG_BACKLIGHT is not set\n")
        sym = self.kconf.syms["BACKLIGHT"]
        self.assertEqual(sym.str_value, "y", "the select wins over the config line")
        self.assertIn("LAPTOP_THING", af.explain_ineffective(sym, "n", "y"))

    def test_promptless_symbol_is_explained_as_inert(self):
        self.load("CONFIG_DRM=y\nCONFIG_DRM_HELPER=y\n")
        sym = self.kconf.syms["DRM_HELPER"]
        self.assertIn("no prompt", af.explain_ineffective(sym, "y", sym.str_value))


if __name__ == "__main__":
    unittest.main()
