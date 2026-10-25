# Expression SPDX de la licence du .rpm (package_license.py), sur des notices factices.
#   python -m unittest discover -s desktop/agent-burn/tools
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
        # AND lie plus que OR : un seul choix au sommet
        self.assertEqual(terms("MIT OR ISC AND Zlib"), ["(ISC AND Zlib OR MIT)"])
        for bad in ("voir LICENSE", "non déclarée", "MIT AND", ""):
            with self.assertRaises(ValueError):
                terms(bad)

    def test_expression_from_notices(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "THIRD-PARTY-NOTICES.txt").write_text(
                "serde 1.0.0\n  Licence : MIT OR Apache-2.0\n  Dépôt : x\n\nitoa 1.0.0\n  Licence : Apache-2.0 OR MIT\n",
                encoding="utf-8")
            (folder / "QT-THIRD-PARTY.txt").write_text(
                "Qt 6.12.0 et PySide6 6.12.0 : en-tête\n\n"
                "ICU 73.2\n  Plateformes : Linux\n  Licence : Unicode-DFS-2016 AND ICU\n\n"
                "zlib 1.3.2\n  Plateformes : Windows\n  Licence : Zlib\n\n"
                "PCRE2 10.48\n  Plateformes : Linux, Windows\n  Licence : BSD-3-Clause\n", encoding="utf-8")
            # choix OR dédoublonnés quel que soit leur ordre ; composants Windows écartés
            self.assertEqual(expression(notices(folder, "Linux") + ["MIT", "LGPL-3.0-only"]),
                             "BSD-3-Clause AND ICU AND LGPL-3.0-only AND MIT AND Unicode-DFS-2016 AND (Apache-2.0 OR MIT)")
            self.assertIn("Zlib", expression(notices(folder, "Windows")))
            self.assertNotIn("ICU", expression(notices(folder, "Windows")))


if __name__ == "__main__":
    unittest.main()
