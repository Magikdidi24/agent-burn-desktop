#!/usr/bin/env python3
# Package license as an SPDX expression: those of the shipped notices ("License:" lines of THIRD-PARTY-NOTICES.txt,
# and of QT-THIRD-PARTY.txt for the platform's components), plus those passed as arguments (app, Qt, Python…).
# Each OR choice stays in parentheses, all joined by AND. Run by linux/build.sh for the .rpm.
#   python package_license.py LICENSES_DIR PLATFORM [EXPRESSION...]
import re
import sys
from pathlib import Path

OPERATORS = ("AND", "OR", "WITH")


def tokens(expr):
    # "MIT/Apache-2.0": old Cargo syntax for OR
    return re.findall(r"\(|\)|[^\s()]+", expr.replace("/", " OR "))


def split(toks, op):
    """toks split on op outside parentheses."""
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
                return toks   # "(A) OR (B)": the 1st parenthesis closes before the end
        toks = toks[1:-1]
    return toks


def text(toks):
    return " ".join(toks).replace("( ", "(").replace(" )", ")")


def _terms(toks):
    toks = unwrap(toks)
    choices = split(toks, "OR")   # OR binds looser than AND: it is at the top if there is one
    if len(choices) > 1:
        return ["(" + " OR ".join(sorted({text(unwrap(c)) for c in choices})) + ")"]
    parts = split(toks, "AND")
    if len(parts) == 1:
        return [text(toks)]
    return [t for part in parts for t in _terms(part)]


def terms(expr):
    """AND terms of an expression; ValueError if it is not one ("see LICENSE", "not declared")."""
    toks = tokens(expr)
    flat = [t for t in toks if t not in ("(", ")")]
    if len(flat) % 2 == 0 or any((t in OPERATORS) != (i % 2 == 1) for i, t in enumerate(flat)):
        raise ValueError(expr)
    return _terms(toks)


def notices(folder, platform):
    found = re.findall(r"^  License: (.+)$", (folder / "THIRD-PARTY-NOTICES.txt").read_text(encoding="utf-8"), re.M)
    for block in (folder / "QT-THIRD-PARTY.txt").read_text(encoding="utf-8").split("\n\n"):
        plat = re.search(r"^  Platforms: (.+)$", block, re.M)
        if plat and platform in plat.group(1).split(", "):
            found.append(re.search(r"^  License: (.+)$", block, re.M).group(1))
    return found


def expression(exprs):
    unique = {t for e in exprs for t in terms(e)}
    return " AND ".join(sorted(unique, key=lambda t: (t.startswith("("), t.lower())))


def main():
    folder, platform, *extra = sys.argv[1:]
    try:
        print(expression(notices(Path(folder), platform) + extra))
    except ValueError as e:
        sys.exit(f"license without an SPDX expression in the notices: “{e}”")


if __name__ == "__main__":
    main()
