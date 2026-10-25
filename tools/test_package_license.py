# SPDX expression of the .rpm license (package_license.py), on fake notices.
#   python -m unittest discover -s tools
import tempfile
import unittest
from pathlib import Path

from package_license import expression, notices, terms


class PackageLicense(unittest.TestCase):
    def test_terms(self):
        self.assertEqual(terms("MIT"), ["MIT"])
        self.assertEqual(terms("MIT/Apache-2.0"), ["(Apache-2.0 OR MIT)"])
        self.assertEqual(terms("(MIT OR Apache-2.0) AND Unicode-3.0"), ["(Apache-2.0 OR MIT)", "Unicode-3.0"])
        self.assertEqual(terms("Apache-2.0 WITH LLVM-exception OR MIT"), ["(Apache-2.0 WITH LLVM-exception OR MIT)"])
        # AND binds tighter than OR: a single choice at the top
        self.assertEqual(terms("MIT OR ISC AND Zlib"), ["(ISC AND Zlib OR MIT)"])
        for bad in ("see LICENSE", "not declared", "MIT AND", ""):
            with self.assertRaises(ValueError):
                terms(bad)

    def test_expression_from_notices(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "THIRD-PARTY-NOTICES.txt").write_text(
                "serde 1.0.0\n  License: MIT OR Apache-2.0\n  Repository: x\n\nitoa 1.0.0\n  License: Apache-2.0 OR MIT\n",
                encoding="utf-8")
            (folder / "QT-THIRD-PARTY.txt").write_text(
                "Qt 6.12.0 and PySide6 6.12.0: header\n\n"
                "ICU 73.2\n  Platforms: Linux\n  License: Unicode-DFS-2016 AND ICU\n\n"
                "zlib 1.3.2\n  Platforms: Windows\n  License: Zlib\n\n"
                "PCRE2 10.48\n  Platforms: Linux, Windows\n  License: BSD-3-Clause\n", encoding="utf-8")
            # OR choices deduplicated whatever their order; Windows components dropped
            self.assertEqual(expression(notices(folder, "Linux") + ["MIT", "LGPL-3.0-only"]),
                             "BSD-3-Clause AND ICU AND LGPL-3.0-only AND MIT AND Unicode-DFS-2016 AND (Apache-2.0 OR MIT)")
            self.assertIn("Zlib", expression(notices(folder, "Windows")))
            self.assertNotIn("ICU", expression(notices(folder, "Windows")))


if __name__ == "__main__":
    unittest.main()
