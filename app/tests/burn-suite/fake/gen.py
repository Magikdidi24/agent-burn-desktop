# Prépare dans DOSSIER le faux CLI et ses fixtures (desktop/agent-burn/tests/fixtures) : dates décalées
# pour que le dernier jour = aujourd'hui, compte Claude daté de maintenant, état du faux CLI remis à zéro.
# Usage : python3 -I gen.py <dossier>
import datetime
import json
import os
import shutil
import sys
import time
from pathlib import Path

here = Path(__file__).resolve().parent
src, out = here.parents[3] / "tests" / "fixtures", sys.argv[1]
shutil.copy2(here / "agent-burn", out)
shift = (datetime.date.today() - datetime.date(2026, 10, 23)).days


def shifted(o):
    if isinstance(o, dict):
        return {k: (datetime.date.fromisoformat(v) + datetime.timedelta(days=shift)).isoformat()
                if k in ("date", "weekStart", "from", "to") and isinstance(v, str) else shifted(v)
                for k, v in o.items()}
    if isinstance(o, list):
        return [shifted(x) for x in o]
    return o


def load(name):
    with open(os.path.join(src, name)) as f:
        return shifted(json.load(f))


def dump(name, o):
    with open(os.path.join(out, name), "w") as f:
        json.dump(o, f)


now = int(time.time() * 1000)
obs = now - 60_000
a = load("summary-live.json")
a["claudeAccount"].update(
    observedAtMs=obs,
    sessionUsedPercent=3.0, sessionResetsAtMs=obs + 4 * 3600_000,      # 20 % de la session écoulée
    weeklyUsedPercent=75.0, weeklyResetsAtMs=obs + 160_628_171,         # 73,44 % de la semaine écoulée
    scoped=[{"name": "Fable", "usedPercent": 0.0, "resetsAtMs": obs + 160_700_000}])
dump("summary-a.json", a)

b = json.loads(json.dumps(a))
for days in (b["daily"], b["agents"][0]["daily"]):
    del days[:2]            # logs de plus de 30 j supprimés par Claude Code
    days[-1]["cost"] = 150.0  # aujourd'hui : usage supplémentaire
    days[-2]["cost"] = 0      # hier : tarifs indisponibles (hors ligne), tokens présents
dump("summary-b.json", b)

r = json.loads(json.dumps(a))
r["totals"]["totalCost"] = 999.99   # marqueur du run --since
dump("summary-range.json", r)

dump("harness-claude.json", load("harness-claude.json"))

for name, text in (("count", "0\n"), ("calls.log", ""), ("mode", "ok\n")):
    with open(os.path.join(out, name), "w") as f:
        f.write(text)
