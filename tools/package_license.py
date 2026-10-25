#!/usr/bin/env python3
# Licence d'un paquet en expression SPDX : celles des notices livrées (lignes « Licence : » de THIRD-PARTY-NOTICES.txt,
# et de QT-THIRD-PARTY.txt pour les composants de la plateforme), plus celles passées en argument (app, Qt, Python…).
# Chaque choix OR reste entre parenthèses, le tout relié par AND. Lancé par linux/build.sh pour le .rpm.
#   python package_license.py DOSSIER_LICENSES PLATEFORME [EXPRESSION...]
import re
import sys
from pathlib import Path

OPERATORS = ("AND", "OR", "WITH")


def tokens(expr):
    # « MIT/Apache-2.0 » : ancienne syntaxe de Cargo pour OR
    return re.findall(r"\(|\)|[^\s()]+", expr.replace("/", " OR "))


def split(toks, op):
    """toks coupé sur op hors parenthèses."""
    parts, depth, cur = [], 0, []
    for t in toks:
        depth += (t == "(") - (t == ")")
        if t == op and depth == 0:
            parts.append(cur)
            cur = []
        else:
            cur.append(t)
    return parts + [cur]


def unwrap(toks):
    while toks[:1] == ["("] and toks[-1:] == [")"]:
        depth = 0
        for i, t in enumerate(toks):
            depth += (t == "(") - (t == ")")
            if depth == 0 and i < len(toks) - 1:
                return toks   # « (A) OR (B) » : la 1re parenthèse se ferme avant la fin
        toks = toks[1:-1]
    return toks


def text(toks):
    return " ".join(toks).replace("( ", "(").replace(" )", ")")


def _terms(toks):
    toks = unwrap(toks)
    choices = split(toks, "OR")   # OR lie moins que AND : il est au sommet s'il y en a un
    if len(choices) > 1:
        return ["(" + " OR ".join(sorted({text(unwrap(c)) for c in choices})) + ")"]
    parts = split(toks, "AND")
    if len(parts) == 1:
        return [text(toks)]
    return [t for part in parts for t in _terms(part)]


def terms(expr):
    """Termes AND d'une expression ; ValueError si ce n'en est pas une (« voir LICENSE », « non déclarée »)."""
    toks = tokens(expr)
    flat = [t for t in toks if t not in ("(", ")")]
    if len(flat) % 2 == 0 or any((t in OPERATORS) != (i % 2 == 1) for i, t in enumerate(flat)):
        raise ValueError(expr)
    return _terms(toks)


def notices(folder, platform):
    found = re.findall(r"^  Licence : (.+)$", (folder / "THIRD-PARTY-NOTICES.txt").read_text(encoding="utf-8"), re.M)
    for block in (folder / "QT-THIRD-PARTY.txt").read_text(encoding="utf-8").split("\n\n"):
        plat = re.search(r"^  Plateformes : (.+)$", block, re.M)
        if plat and platform in plat.group(1).split(", "):
            found.append(re.search(r"^  Licence : (.+)$", block, re.M).group(1))
    return found


def expression(exprs):
    unique = {t for e in exprs for t in terms(e)}
    return " AND ".join(sorted(unique, key=lambda t: (t.startswith("("), t.lower())))


def main():
    folder, platform, *extra = sys.argv[1:]
    try:
        print(expression(notices(Path(folder), platform) + extra))
    except ValueError as e:
        sys.exit(f"licence sans expression SPDX dans les notices : « {e} »")


if __name__ == "__main__":
    main()
