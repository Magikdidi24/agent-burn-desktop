# Graphe de dépendances et rendu des notices sur un faux « cargo metadata » (sans cargo ni réseau).
#   python -m unittest discover -s desktop/agent-burn/tools
import tempfile
import unittest
from pathlib import Path

from third_party_notices import crates, render


def package(root, name, version, source="registry+https://github.com/rust-lang/crates.io-index", **fields):
    folder = Path(root, f"{name}-{version}")
    folder.mkdir()
    for file, text in fields.pop("files", {}).items():
        (folder / file).write_text(text)
    return {"id": f"{name}@{version}", "name": name, "version": version, "source": source,
            "manifest_path": str(folder / "Cargo.toml"), "license": None, "license_file": None,
            "repository": None, "homepage": None, **fields}


def dep(pkg, *kinds):
    return {"pkg": pkg, "dep_kinds": [{"kind": k, "target": None} for k in kinds]}


class Notices(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        mit = "MIT License\n\nCopyright (c) 2026 Exemple\n"
        self.packages = [
            package(tmp.name, "agent-burn", "20.0.21", source=None),
            package(tmp.name, "agent-burn-cli", "0.1.0", source=None),
            package(tmp.name, "serde", "1.0.0", license="MIT OR Apache-2.0", repository="https://github.com/serde-rs/serde",
                    files={"LICENSE-MIT": mit, "LICENSE-APACHE": "Apache License 2.0\n", "README.md": "pas une licence"}),
            package(tmp.name, "itoa", "1.0.0", license="MIT OR Apache-2.0", files={"LICENSE-MIT": mit}),
            package(tmp.name, "ring", "0.17.0", license_file="LICENSE", files={"LICENSE": "ISC et OpenSSL\n"}),
            package(tmp.name, "minreq", "3.0.0", license="ISC"),   # build.rs seulement
            package(tmp.name, "insta", "1.0.0", license="Apache-2.0"),   # tests seulement
            package(tmp.name, "bare", "0.1.0", license="MIT", homepage="https://bare.example"),
        ]
        edges = {
            "agent-burn@20.0.21": [dep("agent-burn-cli@0.1.0", None), dep("serde@1.0.0", None),
                                   dep("minreq@3.0.0", "build"), dep("insta@1.0.0", "dev")],
            "agent-burn-cli@0.1.0": [dep("itoa@1.0.0", None), dep("ring@0.17.0", None, "build")],
            "serde@1.0.0": [dep("bare@0.1.0", None)],
            "minreq@3.0.0": [dep("ring@0.17.0", None)],
        }
        self.meta = {"packages": self.packages, "workspace_members": ["agent-burn@20.0.21", "agent-burn-cli@0.1.0"],
                     "resolve": {"root": None, "nodes": [{"id": p["id"], "deps": edges.get(p["id"], [])}
                                                         for p in self.packages]}}

    def test_only_normal_third_party_dependencies(self):
        # build et dev écartés ; ring reste (aussi dépendance normale) ; crates du dépôt amont exclus
        self.assertEqual([p["name"] for p in crates(self.meta)], ["bare", "itoa", "ring", "serde"])

    def test_render_lists_every_crate_and_copies_each_text_once(self):
        text = render(crates(self.meta))
        self.assertIn("serde 1.0.0\n  Licence : MIT OR Apache-2.0\n  Dépôt : https://github.com/serde-rs/serde", text)
        self.assertIn("ring 0.17.0\n  Licence : voir LICENSE\n  Dépôt : https://crates.io/crates/ring", text)
        self.assertIn("bare 0.1.0\n  Licence : MIT\n  Dépôt : https://bare.example\n"
                      "  Texte de licence : absent du crate, voir le dépôt", text)
        self.assertEqual(text.count("Copyright (c) 2026 Exemple"), 1)
        self.assertIn("Livré par : itoa 1.0.0 (LICENSE-MIT), serde 1.0.0 (LICENSE-MIT)", text)
        self.assertNotIn("pas une licence", text)
        self.assertNotIn("minreq", text)


if __name__ == "__main__":
    unittest.main()
