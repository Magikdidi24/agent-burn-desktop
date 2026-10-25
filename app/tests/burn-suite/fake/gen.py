# Prepares the fake CLI and its fixtures (the repo's tests/fixtures) in DIRECTORY: dates shifted
# so that the last day = today, Claude accounts dated now, fake CLI state reset.
# The summary-<mode>.json files are served when the "mode" file holds <mode> (real CLI outputs, cleaned up).
# Usage: python3 -I gen.py <directory>
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
    sessionUsedPercent=3.0, sessionResetsAtMs=obs + 4 * 3600_000,      # 20% of the session elapsed
    weeklyUsedPercent=75.0, weeklyResetsAtMs=obs + 160_628_171,         # 73.44% of the week elapsed
    scoped=[{"name": "Fable", "usedPercent": 0.0, "resetsAtMs": obs + 160_700_000}])
dump("summary-a.json", a)

b = json.loads(json.dumps(a))
for days in (b["daily"], b["agents"][0]["daily"]):
    del days[:2]            # logs older than 30 d deleted by Claude Code
    days[-1]["cost"] = 150.0  # today: extra usage
    days[-2]["cost"] = 0      # yesterday: pricing unavailable (offline), tokens present
dump("summary-b.json", b)

r = json.loads(json.dumps(a))
r["totals"]["totalCost"] = 999.99   # marker of the --since run
dump("summary-range.json", r)

dump("harness-claude.json", load("harness-claude.json"))

c = load("codex/summary-live.json")
c["claudeAccount"] = a["claudeAccount"]   # same reading as A: Claude stays live
dump("summary-codex.json", c)
del c["claudeAccount"]
dump("summary-noauth.json", c)            # Claude without account: not signed in or offline
dump("summary-empty.json", load("summary-empty-home.json"))
dump("summary-codex-stale.json", load("summary-codex-stale-logs.json"))
dump("summary-expired.json", load("summary-claude-signin-expired.json"))
dump("summary-leak.json", load("summary-quota-env-leak.json"))   # inherited AGENT_BURN_QUOTA_ONLY: no agents[]
i = load("summary-installed-no-usage.json")
i["claudeAccount"].update(observedAtMs=obs, sessionResetsAtMs=obs + 2 * 3600_000, weeklyResetsAtMs=obs + 4 * 86400_000)
dump("summary-installed.json", i)
dump("harness-codex.json.next", load("codex/harness-codex.json"))   # placed by the suite: codex harness fails first
q = load("quota-claude-live.json")
q["observedAt"] = now
dump("quota-claude.json", q)
shutil.copyfile(src / "error-claude-config-dir.stderr.txt", os.path.join(out, "stderr-1.txt"))
shutil.copyfile(src / "error-unknown-flag.stderr.txt", os.path.join(out, "stderr-2.txt"))

for name, text in (("count", "0\n"), ("calls.log", ""), ("mode", "ok\n")):
    with open(os.path.join(out, name), "w") as f:
        f.write(text)
