import Quickshell
import Quickshell.Io
import QtQuick

// Headless test of Burn.qml (no window), under qs and under the desktop app's shim: same expected
// results. Fixtures from tests/fixtures (repo root) served by a fake CLI (fake/). From this directory:
//   qs:   on a copy of this file and of shared/Burn.qml, disposable XDG_*: docs/DEVELOPMENT.md, "Core
//         suite (Burn.qml)" (qs exits with 0 even on failure: read the RESULT line)
//   shim: python ../run_burn_suite.py   (python from the PySide6 venv; code 1 if a test fails)
// BURN_TEST=corrupt: unreadable persisted files → .bak copy, then agent states without an account.
// BURN_TEST=timeout: stuck CLI → summary and light reading killed by the watchdog, timeout lowered to 10 s.
// Burn is referenced only after the seed files are written (singleton created on 1st access).
Scope {
    id: t

    readonly property real day: 86400000
    readonly property string fake: String(Quickshell.env("AGENT_BURN_BIN")).replace(/\/[^\/]*$/, "")
    readonly property bool corrupt: Quickshell.env("BURN_TEST") === "corrupt"
    readonly property bool slow: Quickshell.env("BURN_TEST") === "timeout"
    readonly property string garbage: "{not json " + Date.now()   // unique: an old .bak hides nothing
    property int step: 0
    property int passed: 0
    property int failed: 0
    property real stepAt: 0
    property real seedAt: 0
    property real burnAt: 0
    property real mark: 0

    // console.log is hidden by qs's default log level: assert (ERROR) and info.
    function check(ok, msg) {
        if (ok) passed++;
        else failed++;
        console.assert(ok, "FAIL [step " + step + "] " + msg);
    }
    function eq(a, b, msg) {
        check(a === b, msg + ": expected " + JSON.stringify(b) + ", got " + JSON.stringify(a));
    }
    function near(a, b, eps, msg) {
        check(typeof a === "number" && Math.abs(a - b) <= eps, msg + ": expected ≈" + b + ", got " + a);
    }
    function read(path) { rd.path = path; rd.reload(); return rd.text(); }
    function rawCalls() { return read(fake + "/calls.log").split("\n").filter(l => l); }
    // --config on every call (checked at the end): removed to compare the rest.
    function calls() { return rawCalls().map(l => l.replace(" --config " + Burn.cliConfig, "")); }
    function summaryCalls() { return calls().filter(l => l.startsWith("summary") && l.indexOf("--since") < 0); }
    function last() { return Burn.recentErrors[Burn.recentErrors.length - 1] ?? {}; }
    // Burn.pace() of a Claude window read now, resetting in resetIn ms, with readings [[ms ago, used]];
    // account and readings swapped in for the call, then put back.
    function craftedPace(key, used, resetIn, readings) {
        var acc = Burn.account, smp = Burn.samples, n = Burn.now, a = { observedAtMs: n, scoped: [] }, s = {};
        a[key + "UsedPercent"] = used;
        a[key + "ResetsAtMs"] = n + resetIn;
        s["claude:" + key] = readings.map(r => ({ t: n - r[0], used: r[1] }));
        Burn.account = a;
        Burn.samples = s;
        var p = Burn.pace("claude", key);
        Burn.account = acc;
        Burn.samples = smp;
        return p;
    }
    // Local date at today+offset, chosen separator (independent of Burn).
    function date(offset, sep) {
        var d = new Date();
        d.setDate(d.getDate() + offset);
        var p = n => (n < 10 ? "0" : "") + n;
        return [d.getFullYear(), p(d.getMonth() + 1), p(d.getDate())].join(sep);
    }
    function next() { step++; stepAt = Date.now(); }
    function waited(ms) { return Date.now() - stepAt >= ms; }
    function refreshWith(m) {
        mode.setText(m + "\n");
        mark = summaryCalls().length;
        Burn.refresh(false);
    }
    function refreshed() { return !Burn.loading && summaryCalls().length > mark; }
    function finish() {
        console.info("RESULT: " + passed + " ok, " + failed + " failed");
        step = -1;
        Qt.quit();
    }

    FileView { id: rd; preload: false; blockAllReads: true; printErrors: false }
    FileView { id: histSeed; path: Quickshell.dataPath("burn-history.json"); preload: false; blockWrites: true }
    FileView { id: quotaSeed; path: Quickshell.dataPath("burn-quota.json"); preload: false; blockWrites: true }
    FileView { id: sumSeed; path: Quickshell.dataPath("burn-summary.json"); preload: false; blockWrites: true }
    FileView { id: mode; path: t.fake + "/mode"; preload: false; blockWrites: true }
    FileView { id: codexHarness; path: t.fake + "/harness-codex.json"; preload: false; blockWrites: true }
    Process { id: ipc; command: ["qs", "ipc", "-p", Quickshell.shellDir, "call", "burn", "dashboard"] }

    Component.onCompleted: {
        var n = Date.now();
        seedAt = n;
        if (corrupt) {
            histSeed.setText(garbage);
            quotaSeed.setText(garbage);
            sumSeed.setText(garbage);
        } else {
            histSeed.setText(JSON.stringify({ "2026-08-01": { cost: 5, tokens: 1000, agents: { claude: { cost: 5, tokens: 1000 } } } }));
            quotaSeed.setText(JSON.stringify({
                account: { sessionUsedPercent: 80, sessionResetsAtMs: n - 3600000, weeklyUsedPercent: 50,
                           weeklyResetsAtMs: n + 3 * day, scoped: [], observedAtMs: n - 7200000 },
                samples: { "claude:weekly": [{ t: n - 9 * day, used: 10 }, { t: n - 7200000, used: 50 }] }
            }));
            // Last successful summary from a previous session: empty home (nothing installed).
            sumSeed.setText(JSON.stringify({ at: n - 3 * 3600000, data: JSON.parse(read(fake + "/summary-empty.json")) }));
        }
        next();
    }

    Timer {
        interval: 100; repeat: true; running: t.step > 0
        onTriggered: {
            try { t.tick(); } catch (e) { t.check(false, "exception: " + e + " " + e.stack); t.next(); }
            if (t.step > 0 && t.waited(t.slow ? 30000 : 8000)) { t.check(false, "timed out"); t.finish(); }
        }
    }

    function tick() {
        var w, p, l, ps, u;
        switch (step) {
        case 1:   // 1st access to Burn: persisted state loaded, before the 1st refresh (3 s)
            burnAt = Date.now();
            if (corrupt) {
                eq(Burn.historyDays, 0, "unreadable archive → empty");
                eq(Burn.account, null, "unreadable quota → no account");
                eq(read(Quickshell.dataPath("burn-history.json.bak")), garbage, "raw archive copied to .bak");
                eq(read(Quickshell.dataPath("burn-quota.json.bak")), garbage, "raw quota copied to .bak");
                eq(read(Quickshell.dataPath("burn-summary.json.bak")), garbage, "raw summary copied to .bak");
                eq(Burn.summary, null, "unreadable summary → none");
                eq(Burn.summaryCached, false, "nothing cached");
                eq(Burn.dataState, "unavailable", "dataState without summary");
                eq(Burn.stateText(Burn.dataState), "Unavailable", "stateText unavailable");
                ps = Burn.providerState("claude");
                eq(ps.state, "unknown", "claude before the 1st report");
                eq(ps.label, "Unknown", "label unknown");
                eq(ps.at, 0, "unknown: no reading");
                mode.setText("fail\n");   // the timer's 1st summary: failed
                step = 79;
                next();
                return;
            }
            if (slow) {
                Burn.cliTimeoutMs = 10000;   // 120 s in the app: same watchdog, without a 2-min wait
                mode.setText("slow\n");   // before the 1st refresh (3 s)
                Burn.loadQuota();          // light reading stuck too
                step = 89;
                next();
                return;
            }
            eq(Burn.money(null), "—", "money(null)");
            eq(Burn.money(undefined), "—", "money(undefined)");
            eq(Burn.money(831.8660224199998), "$831.87", "money");
            eq(Burn.money(1075.4374865599998), "$1,075.44", "money thousands");
            eq(Burn.money(0), "$0.00", "money(0)");
            eq(Burn.priced(0, 5), null, "priced: unpriced tokens → unknown");
            eq(Burn.priced(0, 0), 0, "priced: nothing used → 0");
            eq(Burn.priced(1.5, 10), 1.5, "priced: cost kept");
            eq(Burn.priced(null, 10), null, "priced(null)");
            eq(Burn.money(Burn.priced(0, 5)), "—", "never $0.00 without a price");
            eq(Burn.tokens(2005632865), "2.01B", "tokens B");
            eq(Burn.tokens(181976274), "181.98M", "tokens M");
            eq(Burn.tokens(21404), "21.4K", "tokens K");
            eq(Burn.tokens(950), "950", "tokens");
            eq(Burn.tokens(null), "—", "tokens(null)");
            eq(Burn.pct(75), "75%", "pct");
            eq(Burn.pct(74.6), "75%", "pct rounded");
            eq(Burn.pct(null), "—", "pct(null)");
            var n = Burn.now;
            eq(Burn.ago(0), "never", "ago(0)");
            eq(Burn.ago(n), "just now", "ago(now)");
            eq(Burn.ago(n - 12000), "12 s ago", "ago s");
            eq(Burn.ago(n - 180000), "3 min ago", "ago min");
            eq(Burn.ago(n - 7200000), "2 h ago", "ago h");
            eq(Burn.ago(n - 3 * day), "3 d ago", "ago d");
            eq(Burn.until(n + (4 * 3600 + 12 * 60 + 30) * 1000), "in 4 h 12 min", "until h");
            eq(Burn.until(n + (4 * 3600 + 5 * 60) * 1000), "in 4 h 05 min", "until h 0x");
            eq(Burn.until(n + (2 * 86400 + 3 * 3600 + 30) * 1000), "in 2 d 3 h", "until d");
            eq(Burn.until(n + 12 * 60000 + 5000), "in 12 min", "until min");
            eq(Burn.until(n - 1000), "now", "until past");
            eq(Burn.until(0), "—", "until(0)");
            eq(Burn.agentName("claude"), "Claude Code", "agentName");
            eq(Burn.agentName("opencode"), "OpenCode", "agentName opencode");
            eq(Burn.agentName("zz"), "zz", "agentName unknown");
            check(String(Burn.agentIcon("claude")).endsWith("assets/burn/claude.png"), "agentIcon " + Burn.agentIcon("claude"));
            eq(Burn.agentIcon("zz"), "", "agentIcon unknown");
            eq(String(Burn.agentColor("claude")), "#d97757", "agentColor");
            eq(String(Burn.agentColor("codex")), "#10a37f", "agentColor codex");
            eq(String(Burn.agentColor("pi")), "#6b7280", "agentColor without brand");
            eq(String(Burn.agentColor("zz")), "#6b7280", "agentColor default");
            eq(Object.keys(Burn.providers).join(","), "claude,codex,cursor,opencode,gemini,pi,droid,openclaw,kimi,amp,qwen",
               "provider registry");
            eq(Object.keys(Burn.providers).filter(a => Burn.providers[a].harness).join(","), "claude,codex", "harness: claude|codex");
            eq(Burn.names.qwen, "Qwen", "names read from the registry");
            eq(JSON.stringify(Burn.knownProviders), '["claude","codex"]', "knownProviders");
            eq(Burn.stateText("live"), "Live", "stateText live");
            eq(Burn.stateText("cached"), "Cached", "stateText cached");
            eq(Burn.stateText("unavailable"), "Unavailable", "stateText unavailable");
            eq(Burn.cliHint, "agent-burn CLI not found (~/.local/bin/agent-burn): rerun install.sh", "default cliHint");
            eq(Burn.cliConfig, Quickshell.dataPath("agent-burn-cli.json"), "cliConfig in the data folder");
            eq(Burn.refreshInterval, 300000, "default cadence 5 min");
            eq(Burn.accessibleText, false, "texts not exposed by default (bar: threaded render loop)");

            check(Burn.summary !== null && Burn.summary.agents.length === 0, "cached summary reread at startup");
            eq(Burn.summaryCached, true, "summaryCached");
            eq(Burn.updatedAt, seedAt - 3 * 3600000, "updatedAt of the cached summary");
            eq(Burn.dataState, "cached", "dataState: cached");
            eq(Burn.stateText(Burn.dataState), "Cached", "stateText of the cached summary");
            eq(Burn.pricingMissing, false, "empty home: no missing pricing");
            eq(Burn.recentErrors.length, 0, "no failure");
            eq(JSON.stringify(Burn.harnessErrors), "{}", "no harness failure");
            eq(JSON.stringify(Burn.agents), '["claude"]', "agents: those of the archive before the 1st summary");
            eq(Burn.account.weeklyUsedPercent, 50, "persisted account");
            ps = Burn.providerState("claude");
            eq(ps.state, "stale", "claude: persisted account 2 h old");
            eq(ps.label, "Stale reading", "label stale");
            eq(ps.at, seedAt - 7200000, "at = account reading");
            eq(ps.error, "", "claude without error");
            ps = Burn.providerState("codex");
            eq(ps.state, "none", "codex: no usage and no subscription");
            eq(ps.label, "Not detected", "label none");
            eq(ps.at, seedAt - 3 * 3600000, "at = cached summary");
            w = Burn.windows("claude");
            eq(w.map(x => x.key).join(","), "session,weekly", "windows of the persisted account");
            eq(w[0].used, 0, "past session → reset");
            eq(w[0].remaining, 100, "reset session → 100% left");
            eq(w[0].resetsAtMs, 0, "session: next reset unknown");
            eq(w[1].used, 50, "weekly used");
            eq(w[1].remaining, 50, "weekly remaining");
            eq(w[1].resetsAtMs, seedAt + 3 * day, "weekly resetsAtMs");
            eq(w[1].startMs, seedAt - 4 * day, "weekly startMs");
            eq(w[1].durationMin, 10080, "weekly durationMin");
            eq(Burn.windows("codex").length, 0, "codex without subscription");
            eq(Burn.remaining, 50, "remaining");
            eq(Burn.remainingKey, "wk", "remainingKey");
            eq(Burn.remainingAgent, "claude", "remainingAgent");
            eq(Burn.remainingWindow, "weekly", "remainingWindow");
            p = Burn.pace("claude", "weekly");
            eq(p.status, "good", "persisted pace");
            eq(p.used, 50, "pace used");
            near(p.elapsed, 94 / 168, 1e-6, "pace elapsed (at the reading)");
            near(p.projected, 50 * 168 / 94, 1e-3, "pace projected");
            eq(p.exhaustAtMs, 0, "no exhaustion");
            eq(p.title, "Room to keep going", "pace title");
            eq(Burn.pace("claude", "session").status, "good", "reset session → good");
            eq(Burn.pace("claude", "session").projected, -1, "session without usage → no projection");
            eq(Burn.pace("claude", "nope").status, "unknown", "unknown window");
            eq(Burn.pace("claude", "nope").used, null, "unknown window: used null");
            // Pace follows the curve: speed over the last day of a week (last hour of a session), against
            // the speed that ends at 0% left exactly at the reset. Week started 4 d ago, 3 d left.
            p = craftedPace("weekly", 48, 3 * day, [[2 * day, 24], [day, 36]]);
            eq(p.status, "good", "steady 12%/day for 52% in 3 d → good");
            eq(p.title, "Room to keep going", "steady title");
            near(p.projected, 48 + 3 * 12, 1e-6, "steady projection");
            eq(p.detail, "At this pace, about 16% left at the reset.", "steady detail");
            p = craftedPace("weekly", 50, 3 * day, [[day, 32]]);
            eq(p.status, "warn", "18%/day for 16.7%/day → warn");
            eq(p.title, "Pace slightly too fast", "slightly too fast title");
            near(p.projected, 50 + 3 * 18, 1e-6, "slightly too fast projection");
            p = craftedPace("weekly", 50, 3 * day, [[day, 25]]);
            eq(p.status, "warn", "1.5× the sustainable pace → warn");
            eq(p.title, "Pace too fast", "too fast title");
            near(p.ratio, 1.5, 1e-6, "too fast ratio");
            // Free fall: 12.5%/day on average since the start (the old verdict: room to keep going), 40% in the last day.
            p = craftedPace("weekly", 50, 3 * day, [[day, 10]]);
            eq(p.status, "danger", "free fall → danger");
            eq(p.title, "Pace way too fast", "free fall title");
            near(p.projected, 50 + 3 * 40, 1e-6, "free fall projection");
            near(p.ratio, 2.4, 1e-6, "free fall ratio");
            near(p.exhaustAtMs, Burn.now + 1.25 * day, 1000, "free fall: 50% left at 40%/day");
            check(p.detail.startsWith("2.4× the sustainable pace: runs out ≈ "), "free fall detail — " + p.detail);
            check(p.detail.endsWith(" before the reset. Stay under 16.7%/day."), "free fall advice — " + p.detail);
            // Slowed down: too fast on average (70% in 4 d), flat for 2 days.
            p = craftedPace("weekly", 70, 3 * day, [[2 * day, 70]]);
            eq(p.status, "good", "flat curve → good");
            near(p.projected, 70, 1e-6, "flat curve projection");
            // A day ago falls between two readings: interpolated (16%).
            p = craftedPace("weekly", 40, 3 * day, [[30 * 3600000, 10], [18 * 3600000, 22]]);
            near(p.projected, 40 + 3 * 24, 1e-6, "interpolated reading");
            eq(p.title, "Pace slightly too fast", "interpolated: 1.2×");
            // Session (5 h): last hour, advice per hour.
            p = craftedPace("session", 50, 2 * 3600000, [[3600000, 20]]);
            eq(p.title, "Pace slightly too fast", "session 30%/h for 25%/h");
            near(p.projected, 50 + 2 * 30, 1e-6, "session projection");
            check(p.detail.endsWith("Stay under 25.0%/h."), "session advice per hour — " + p.detail);
            // 5 min into a session with 4% used: a burst is not a trend yet (speed over 30 min at least).
            p = craftedPace("session", 4, 295 * 60000, []);
            eq(p.status, "good", "burst at the start of a session → good");
            near(p.projected, 4 + 4 * 295 / 30, 1e-6, "session start: speed over 30 min");
            // First day of a week, 9 h of work on budget (14%/day): a full day at least, nights included.
            p = craftedPace("weekly", 14, 7 * day - 9 * 3600000, []);
            eq(p.title, "Pace slightly too fast", "first workday of a week on budget → not red");
            check(p.detail.startsWith("Runs out ≈ "), "slightly too fast: no multiple — " + p.detail);
            // Titles follow the multiple as written (one decimal): 1.26× → 1.3×, 1.96× → 2.0×.
            p = craftedPace("weekly", 30, 5 * day, [[day, 12.36]]);
            eq(p.title, "Pace too fast", "1.26× → too fast");
            check(p.detail.startsWith("1.3× the sustainable pace"), "1.26× written 1.3× — " + p.detail);
            p = craftedPace("weekly", 30, 5 * day, [[day, 2.56]]);
            eq(p.status, "danger", "1.96× → danger");
            check(p.detail.startsWith("2.0× the sustainable pace"), "1.96× written 2.0× — " + p.detail);
            p = craftedPace("weekly", 30, 5 * day, [[day, 2.84]]);
            eq(p.title, "Pace too fast", "1.94× → too fast");
            p = craftedPace("weekly", 100, day, [[day, 60]]);
            eq(p.title, "Limit reached", "nothing left → limit reached");
            l = Burn.quotaSamples("claude", "weekly");
            eq(l.length, 1, "sample outside the window excluded");
            eq(l.length && l[0].used, 50, "persisted sample");
            eq(Burn.historyDays, 1, "persisted archive, cached summary not merged");
            eq(Burn.dailySeries("").length && Burn.dailySeries("")[0].date, "2026-08-01", "dailySeries archive");
            eq(Burn.dailySeries("codex").length, 0, "dailySeries missing agent");
            check(Burn.dataDir.length > 0, "dataDir");
            // Dashboard open at launch: summary right away, harness requested while it runs.
            mode.setText("delay\n");
            Burn.poke();
            Burn.loadHarness("claude");
            next();
            break;
        case 2:
            if (calls().length === 0) return;
            check(Burn.loading && !calls().some(c => c.startsWith("harness")), "harness deferred during the summary: " + calls());
            next();
            break;
        case 3:   // 1st summary (fixture A) then the deferred harness; 3-s timer elapsed
            if (Burn.summaryCached || !Burn.harnesses.claude || Burn.loading || Date.now() - burnAt < 3600) return;
            mode.setText("ok\n");
            eq(JSON.stringify(calls()), JSON.stringify(["summary --value --json --no-color FORCE=0",
                "harness claude --value --json --no-color FORCE=0"]), "a single summary at startup, then the harness");
            near(Burn.summary.totals.totalCost, 831.866, 0.001, "summary loaded");
            eq(Burn.summaryCached, false, "live summary");
            eq(Burn.dataState, "live", "dataState live");
            eq(Burn.pricingMissing, false, "pricing present");
            ps = Burn.providerState("claude");
            eq(ps.state, "live", "claude live");
            eq(ps.label, "Live", "label live");
            eq(ps.at, Burn.account.observedAtMs, "at = account reading");
            eq(Burn.providerState("codex").state, "none", "codex still absent");
            eq(JSON.stringify(Burn.agents), '["claude"]', "agents");
            eq(Burn.agentEntry("claude").totalTokens, 2005632865, "agentEntry");
            eq(Burn.agentEntry("zz"), null, "agentEntry missing");
            eq(Burn.subEntry("claude").plan, "Max 5×", "subEntry");
            eq(Burn.subEntry("zz"), null, "subEntry missing");
            eq(Burn.error, "", "no error");
            eq(Burn.cliMissing, false, "CLI present");
            w = Burn.windows("claude");
            eq(w.map(x => x.key).join(","), "session,weekly,scoped:Fable", "keys");
            eq(w.map(x => x.label).join(","), "5-hour session,Week,Fable · week", "labels");
            eq(w.map(x => x.short).join(","), "5 h,wk,Fable", "short labels");
            eq(w[0].used, 3, "session used");
            eq(w[0].durationMin, 300, "session 300 min");
            eq(w[0].startMs, w[0].resetsAtMs - 300 * 60000, "session startMs");
            eq(w[1].remaining, 25, "weekly remaining");
            eq(w[2].durationMin, 10080, "scoped weekly");
            eq(Burn.remaining, 25, "remaining = tightest window");
            eq(Burn.remainingKey, "wk", "remainingKey");
            eq(Burn.remainingWindow, "weekly", "remainingWindow");
            // 50% two hours ago (persisted reading), 75% now: free fall, far beyond the CLI's linear estimate (102%).
            p = Burn.pace("claude", "weekly");
            u = Burn.account.observedAtMs - day;   // on the line from the start of the week (0%) to the 50% reading
            u = 50 * (u - w[1].startMs) / (seedAt - 7200000 - w[1].startMs);
            near(p.projected, 75 + (75 - u) * (w[1].resetsAtMs - Burn.account.observedAtMs) / day, 1e-6, "projection from the last day");
            eq(p.status, "danger", "75% now, 50% 2 h ago → danger");
            eq(p.title, "Pace way too fast", "title danger");
            check(p.detail.indexOf("%/day") > 0, "detail: advised pace per day — " + p.detail);
            console.info("pace weekly: " + p.title + " — " + p.detail);
            p = Burn.pace("claude", "session");
            eq(p.status, "good", "session good");
            near(p.projected, 15, 0.01, "session projected");
            eq(Burn.historyDays, 16, "archive: 15 days + 1 old");
            near(Burn.history[date(0, "-")].cost, 102.055, 0.001, "archive today");
            eq(Burn.history["2026-08-01"].cost, 5, "old day kept");
            l = Burn.dailySeries("");
            eq(l.length, 16, "dailySeries all agents");
            check(l.every((d, i) => i === 0 || l[i - 1].date < d.date), "dailySeries sorted");
            eq(Burn.dailySeries("claude").length, 16, "dailySeries claude");
            near(Burn.spendSince("", 7), 806.578, 0.001, "spendSince 7 d");
            near(Burn.spendSince("claude", 1), 102.055, 0.001, "spendSince today");
            eq(Burn.spendSince("codex", 7), 0, "spendSince missing agent");
            l = Burn.quotaSamples("claude", "weekly");
            eq(l.length, 2, "sample added");
            check(l.length === 2 && l[0].t < l[1].t && l[1].used === 75, "samples sorted");
            eq(Burn.quotaSamples("claude", "session").length, 1, "session sample");
            eq(Burn.quotaSamples("claude", "scoped:Fable").length, 1, "scoped sample");
            Burn.poke();              // fresh summary: ignored
            mark = Burn.updatedAt;
            Burn.refresh(true);
            Burn.refresh(false);      // already running: ignored
            next();
            break;
        case 4:   // 2nd summary (fixture B: old days deleted, today $150, yesterday at $0)
            if (Burn.updatedAt === mark || Burn.loading) return;
            l = summaryCalls();
            eq(l.length, 2, "poke and concurrent refresh ignored");
            eq(l[0], "summary --value --json --no-color FORCE=0", "arguments like the Mac app");
            eq(l[1], "summary --value --json --no-color FORCE=1", "force → AGENT_BURN_FORCE_REFRESH=1");
            eq(Burn.historyDays, 16, "days gone from the logs kept");
            check(Burn.history[date(-25, "-")] !== undefined, "oldest day kept");
            near(Burn.history[date(0, "-")].cost, 150, 0.001, "present day replaced");
            near(Burn.history[date(-1, "-")].cost, 489.289, 0.001, "cost 0 with tokens > 0 ignored");
            eq(Burn.history[date(-1, "-")].tokens, 1199324996, "yesterday's tokens");
            eq(Burn.summary.daily.length, 13, "summary replaced");
            near(Burn.spendSince("", 7), 806.578 - 102.055 + 150, 0.001, "spendSince after merge");
            eq(Burn.quotaSamples("claude", "weekly").length, 2, "same observedAtMs → no duplicate");
            Burn.setRange("7d");
            eq(Burn.range, "7d", "range");
            eq(Burn.rangeSummary, null, "rangeSummary null during its 1st load");
            next();
            break;
        case 5:   // run --since
            if (Burn.rangeSummary === null) return;
            near(Burn.rangeSummary.totals.totalCost, 999.99, 0.001, "rangeSummary");
            l = calls();
            eq(l[l.length - 1], "summary --value --json --no-color --since " + date(-6, "") + " FORCE=0", "--since YYYYMMDD");
            mark = l.length;
            Burn.setRange("all");
            check(Burn.rangeSummary === Burn.summary, "all → summary");
            Burn.setRange("7d");      // cached: no new run
            near(Burn.rangeSummary.totals.totalCost, 999.99, 0.001, "cached rangeSummary");
            Burn.setRange("bogus");
            eq(Burn.range, "7d", "unknown range ignored");
            next();
            break;
        case 6:
            if (!waited(400)) return;
            eq(calls().length, mark, "cached range: no run");
            Burn.loadHarness("claude");   // loaded at step 3, fresh: ignored
            Burn.loadHarness("cursor");   // CLI: claude|codex only
            next();
            break;
        case 7:
            if (!Burn.harnesses.claude) return;
            eq(Burn.harnesses.claude.plan, "Max 5×", "harness loaded");
            eq(Burn.harnesses.claude.window.windowMinutes, 10080, "harness window");
            mark = calls().length;
            Burn.loadHarness("claude");   // fresh: ignored
            next();
            break;
        case 8:   // persisted files (save deferred by 1 s)
            if (!waited(1500)) return;
            eq(calls().length, mark, "fresh harness: no run");
            check(!calls().some(c => c.startsWith("harness cursor")), "harness cursor never launched");
            var h = JSON.parse(read(Quickshell.dataPath("burn-history.json")));
            eq(Object.keys(h).length, 16, "archive written");
            near(h[date(-1, "-")].cost, 489.289, 0.001, "archive written: yesterday");
            eq(h["2026-08-01"].agents.claude.tokens, 1000, "archive written: old day");
            var q = JSON.parse(read(Quickshell.dataPath("burn-quota.json")));
            eq(q.account.observedAtMs, Burn.account.observedAtMs, "account written");
            eq(q.samples["claude:weekly"].length, 2, "sample > 8 d purged");
            eq(q.samples["claude:session"].length, 1, "session samples written");
            var s = JSON.parse(read(Quickshell.dataPath("burn-summary.json")));
            eq(s.at, Burn.updatedAt, "summary written: time of the run");
            eq(s.data.daily.length, 13, "summary written: the latest (B)");
            mode.setText("fail\n");
            mark = Burn.updatedAt;
            Burn.refresh(false);
            next();
            break;
        case 9:
            if (Burn.loading || Burn.error === "") return;
            eq(Burn.error, "agent-burn failed (code 3)", "exit code, empty stderr");
            check(Burn.summary !== null && Burn.updatedAt === mark, "summary kept on failure");
            check(Burn.account !== null, "account kept on failure");
            eq(Burn.dataState, "cached", "last summary failed → cached");
            eq(last().source, "summary", "recentErrors: source");
            eq(last().msg, Burn.error, "recentErrors: message");
            check(last().t > 0 && Date.now() - last().t < 5000, "recentErrors: time");
            mode.setText("err1\n");
            Burn.refresh(false);
            next();
            break;
        case 10:   // code 1: WARN then Error: CliError("…") (invalid CLAUDE_CONFIG_DIR, real output)
            if (Burn.loading || Burn.error.indexOf("code 1") < 0) return;
            var head = "agent-burn failed (code 1): ";
            check(Burn.error.startsWith(head + "No valid Claude data directories found in CLAUDE_CONFIG_DIR."),
                  "detail: Error: line unwrapped, WARN ignored — " + Burn.error);
            eq(Burn.error.length - head.length, 160, "detail truncated to 160 characters");
            check(Burn.error.endsWith("…") && Burn.error.indexOf("CliError") < 0, "detail truncated and unwrapped");
            mode.setText("err2\n");
            Burn.refresh(false);
            next();
            break;
        case 11:   // code 2: unknown option (CLI of another version)
            if (Burn.loading || Burn.error.indexOf("Incompatible") < 0) return;
            eq(Burn.error, "Incompatible agent-burn CLI: Unknown summary option '--frobnicate'", "code 2: 1st stderr line");
            mode.setText("garbage\n");
            Burn.refresh(false);
            next();
            break;
        case 12:
            if (Burn.loading || Burn.error.indexOf("unreadable") < 0) return;
            check(Burn.error.indexOf("unreadable") >= 0, "JSON error: " + Burn.error);
            eq(Burn.cliMissing, false, "CLI present");
            check(JSON.stringify(Burn.recentErrors).indexOf("not json") < 0, "recentErrors without the stdout");
            refreshWith("leak");
            next();
            break;
        case 13:   // inherited AGENT_BURN_QUOTA_ONLY: valid JSON without agents[]
            if (!refreshed()) return;
            eq(Burn.error, "agent-burn returned an unreadable report.", "report without agents[] → unreadable");
            eq(Burn.summary.daily.length, 13, "summary B kept");
            Burn.bin = "/nonexistent/agent-burn";
            Burn.refresh(false);
            next();
            break;
        case 14:
            if (!Burn.cliMissing) return;
            check(Burn.error.indexOf("not found") >= 0, "missing CLI error: " + Burn.error);
            ps = Burn.providerState("claude");
            eq(ps.state, "unavailable", "missing CLI → unavailable");
            eq(ps.label, "CLI not found", "label unavailable");
            eq(ps.detail, Burn.cliHint, "detail = host's remedy");
            eq(ps.at, 0, "unavailable: no reading");
            eq(last().source, "cli", "recentErrors: missing CLI");
            eq(Burn.dataState, "cached", "missing CLI → cached");
            Burn.bin = Quickshell.env("AGENT_BURN_BIN");
            mode.setText("ok\n");
            mark = Burn.updatedAt;
            Burn.refresh(false);
            next();
            break;
        case 15:
            if (Burn.cliMissing || Burn.loading || Burn.updatedAt === mark) return;
            eq(Burn.error, "", "error cleared on success");
            eq(Burn.dataState, "live", "success → live");
            u = Burn.updatedAt;
            Burn.refreshInterval = 1000;   // < 1 min: counted as 1 min
            Burn.now = Date.now();
            Burn.updatedAt = Burn.now - 3600000 - 190000;
            eq(Burn.dataState, "cached", "older than 1 h + cadence (1 min floor) + 2 min of run → cached");
            Burn.updatedAt = Burn.now - 3600000 - 170000;
            eq(Burn.dataState, "live", "1 h 2 min 50 s: hourly summary running, still live");
            Burn.refreshInterval = 300000;
            Burn.updatedAt = u;
            // Claude reading stale after 2 background rounds, 10 min at least.
            var acc = Burn.account;
            Burn.account = Object.assign({}, acc, { observedAtMs: Burn.now - 11 * 60000 });
            eq(Burn.limitsStale, true, "cadence 5 min: 11-min-old reading is stale");
            eq(Burn.providerState("claude").detail, "Last known limits: no reading for more than 10 min.",
               "detail: 10-min threshold");
            Burn.refreshInterval = 900000;
            eq(Burn.limitsStale, false, "cadence 15 min: 11-min-old reading still recent");
            Burn.account = Object.assign({}, acc, { observedAtMs: Burn.now - 31 * 60000 });
            eq(Burn.limitsStale, true, "cadence 15 min: stale after 2 rounds");
            eq(Burn.providerState("claude").detail, "Last known limits: no reading for more than 30 min.",
               "detail: 2-round threshold");
            Burn.refreshInterval = 300000;
            Burn.account = acc;
            eq(Burn.limitsStale, false, "recent reading restored");
            eq(Burn.dashboardOpen, false, "dashboard closed");
            // Replayed from exited: running must already be false there (otherwise nothing is relaunched).
            mark = summaryCalls().length;
            Burn.refresh(false);
            Burn.refresh(true);
            next();
            break;
        case 16:
            if (Burn.loading || !waited(1500)) return;
            eq(JSON.stringify(summaryCalls().slice(mark)), JSON.stringify(["summary --value --json --no-color FORCE=0",
                "summary --value --json --no-color FORCE=1"]), "refresh(true) during a run: replayed forced at its end");
            eq(Burn.pendingForce, false, "pendingForce consumed");
            mark = calls().length;
            Burn.setRange("30d");
            Burn.setRange("today");   // during the 30-day --since run
            next();
            break;
        case 17:
            if (Burn.loading || !waited(1500)) return;
            eq(JSON.stringify(calls().slice(mark)), JSON.stringify(["summary --value --json --no-color --since " + date(-29, "")
                + " FORCE=0", "summary --value --json --no-color --since " + date(0, "") + " FORCE=0"]),
               "range changed during a run: relaunched on the new one at its end");
            check(Burn.rangeSummary !== null, "rangeSummary of the new range");
            refreshWith("codex");
            next();
            break;
        case 18:   // Claude + Codex (Codex limits from recent logs)
            if (!refreshed()) return;
            check(Burn.agents.indexOf("codex") >= 0, "codex among the agents");
            w = Burn.windows("codex");
            eq(w.map(x => x.key).join(","), "session,weekly", "codex windows");
            eq(w.map(x => x.used).join(","), "12,34", "codex used");
            near(w[1].resetsAtMs, Burn.updatedAt + (10080 - Burn.subEntry("codex").window.elapsedMinutes) * 60000, 1, "codex weekly reset");
            ps = Burn.providerState("codex");
            eq(ps.state, "live", "codex live");
            eq(ps.at, Burn.updatedAt, "codex at = summary");
            eq(ps.error, "", "codex without error");
            eq(Burn.providerState("claude").state, "live", "claude still live");
            eq(Burn.quotaSamples("codex", "weekly").length, 1, "codex reading recorded");
            Burn.loadHarness("codex");   // no fixture: failure
            next();
            break;
        case 19:
            if (Burn.loading || !Burn.harnessErrors.codex) return;
            eq(Burn.harnessErrors.codex, 'agent-burn failed (code 1): no fixture "harness-codex.json" in C:\\fake',
               "harness error: CliError unwrapped, \\\" and \\\\ restored");
            eq(Burn.error, "", "harness error kept out of the global error");
            eq(Burn.providerState("codex").error, Burn.harnessErrors.codex, "error on the agent concerned");
            eq(Burn.providerState("claude").error, "", "the other agents stay clean");
            eq(last().source, "harness:codex", "recentErrors: harness");
            eq(Burn.harnesses.codex, undefined, "no codex harness");
            codexHarness.setText(read(fake + "/harness-codex.json.next"));
            Burn.loadHarness("codex");
            next();
            break;
        case 20:
            if (Burn.loading || !Burn.harnesses.codex) return;
            eq(Burn.harnesses.codex.plan, "Plus", "codex harness loaded");
            check(!Burn.harnessErrors.hasOwnProperty("codex"), "codex error cleared on success");
            eq(Burn.providerState("codex").error, "", "codex clean");
            refreshWith("codex-stale");
            next();
            break;
        case 21:   // Codex logs 9-10 days old: liveLimits true, week over
            if (!refreshed()) return;
            eq(Burn.windows("codex").length, 0, "expired reading: neither week nor session");
            eq(Burn.subEntry("codex").window.usedPercent, 91, "the report keeps the old reading");
            ps = Burn.providerState("codex");
            eq(ps.state, "local", "codex: usage without limits");
            eq(ps.label, "Local usage", "label local");
            eq(Burn.remainingAgent, "claude", "pill: never Codex's old %");
            refreshWith("expired");
            next();
            break;
        case 22:   // sign-in expired (or expired token without network) and bundled pricing at $0
            if (!refreshed()) return;
            eq(Burn.signInExpired, true, "signInExpired");
            eq(Burn.limitsStale, true, "limits flagged stale");
            ps = Burn.providerState("claude");
            eq(ps.state, "expired", "claude: check sign-in");
            eq(ps.label, "Check sign-in", "label expired");
            check(ps.detail.indexOf("network") >= 0 && ps.detail.indexOf("/login") >= 0, "detail: network or /login — " + ps.detail);
            eq(ps.at, Burn.account.observedAtMs, "expired: reading kept");
            eq(Burn.pricingMissing, true, "tokens at $0 → missing pricing");
            eq(Burn.priced(Burn.summary.totals.totalCost, Burn.summary.totals.totalTokens), null, "total without price → unknown");
            eq(Burn.dataState, "live", "fresh data despite the pricing");
            Burn.loadQuota();
            next();
            break;
        case 23:   // light reading (AGENT_BURN_QUOTA_ONLY)
            if (Burn.account.weeklyUsedPercent !== 3) return;
            var r = JSON.parse(read(fake + "/quota-claude.json"));
            eq(calls()[calls().length - 1], "harness claude --json --no-color FORCE=0 QUOTA=1", "light reading: arguments and env");
            eq(Burn.account.observedAtMs, r.observedAt, "reading dated");
            near(Burn.account.weeklyResetsAtMs, r.observedAt + (100 - r.window.elapsedPercent) * r.window.windowMinutes * 600, 1,
                 "weekly reset");
            eq(Burn.account.sessionUsedPercent, 22, "session of the reading");
            eq(Burn.signInExpired, false, "direct reading: sign-in restored");
            eq(Burn.providerState("claude").state, "live", "claude live again");
            mode.setText("fail\n");
            mark = Burn.recentErrors.length;
            Burn.loadQuota();
            next();
            break;
        case 24:   // failed light reading: silent
            if (Burn.recentErrors.length === mark) return;
            eq(last().source, "quota", "failure noted");
            eq(last().msg, "agent-burn failed (code 3)", "reading message");
            eq(Burn.error, "", "silent UI");
            eq(Burn.account.weeklyUsedPercent, 3, "last reading kept");
            mode.setText("ok\n");
            Burn.bin = "/nonexistent/agent-burn";
            mark = Burn.recentErrors.length;
            Burn.loadQuota();
            next();
            break;
        case 25:   // light reading without CLI: silent too, cliMissing left to the summary
            if (Burn.recentErrors.length === mark) return;
            eq(last().source, "quota", "launch failure noted");
            check(last().msg.indexOf("not found") >= 0, "message: " + last().msg);
            eq(Burn.cliMissing, false, "cliMissing intact");
            eq(Burn.error, "", "silent UI");
            Burn.bin = Quickshell.env("AGENT_BURN_BIN");
            // Dashboard opened during a summary: range loaded at its end, never in parallel (429).
            mode.setText("delay\n");
            Burn.rangeCache = ({});
            mark = calls().length;
            Burn.refresh(false);
            Burn.dashboardOpen = true;
            next();
            break;
        case 26:
            if (calls().length === mark) return;
            check(Burn.loading && !calls().slice(mark).some(c => c.indexOf("--since") >= 0),
                  "range deferred during the summary: " + calls().slice(mark));
            next();
            break;
        case 27:
            l = calls().slice(mark);
            if (Burn.loading || !l.some(c => c.indexOf("--since") >= 0)) return;
            check(l[0].startsWith("summary --value --json --no-color FORCE=0") && l[0].indexOf("--since") < 0,
                  "summary first, range next: " + l);
            // Opened the way the windows do it (dashboardOpen then the poke() of their load()), data and range outdated.
            Burn.dashboardOpen = false;
            Burn.rangeCache = ({});
            Burn.updatedAt = Date.now() - 120000;   // more than 1 min: poke() relaunches the summary
            mark = calls().length;
            Burn.dashboardOpen = true;
            Burn.poke();
            next();
            break;
        case 28:
            if (calls().length === mark || !waited(300)) return;
            check(Burn.loading && JSON.stringify(calls().slice(mark)) === JSON.stringify(["summary --value --json --no-color FORCE=0"]),
                  "opening: summary alone, range deferred: " + calls().slice(mark));
            next();
            break;
        case 29:
            l = calls().slice(mark);
            if (Burn.loading || l.length < 2) return;
            eq(JSON.stringify(l), JSON.stringify(["summary --value --json --no-color FORCE=0",
                "summary --value --json --no-color --since " + date(0, "") + " FORCE=0"]), "opening: summary, then the range at its end");
            // Range running then refresh() (timer, Refresh): summary deferred to the end of the range, forced once.
            Burn.rangeCache = ({});
            mark = calls().length;
            Burn.setRange("7d");
            Burn.refresh(false);
            Burn.refresh(true);
            next();
            break;
        case 30:
            if (calls().length === mark || !waited(300)) return;
            l = calls().slice(mark);
            check(Burn.loading && l.length === 1 && l[0].indexOf("--since " + date(-6, "")) > 0,
                  "refresh during the range: deferred: " + l);
            eq(Burn.pendingRefresh, true, "summary waiting for the range");
            next();
            break;
        case 31:
            l = calls().slice(mark);
            if (Burn.loading || l.length < 2) return;
            eq(l[1], "summary --value --json --no-color FORCE=1", "range first, forced summary at its end");
            eq(l.filter(c => c.startsWith("summary") && c.indexOf("--since") < 0).length, 1, "a single summary replayed");
            check(!Burn.pendingRefresh && !Burn.pendingForce, "pending requests consumed");
            mode.setText("ok\n");
            Burn.dashboardOpen = false;
            ipc.running = true;
            next();
            break;
        case 32:
            if (!Burn.dashboardOpen) return;
            check(true, "IPC burn dashboard");
            l = rawCalls();
            check(l.length > 15 && l.every(c => c.indexOf(" --config " + Burn.cliConfig + " ") > 0),
                  "--config on every call (" + l.length + "): " + l.filter(c => c.indexOf("--config") < 0));
            eq(read(Burn.cliConfig), "", "CLI config never created");
            for (var i = 0; i < 25; i++) Burn.note("test", "n" + i);
            eq(Burn.recentErrors.length, 20, "recentErrors: 20 at most");
            eq(last().msg, "n24", "most recent last");
            finish();
            break;
        case 80:   // corrupt: the timer's 1st summary (nothing ran) failed, still no report
            if (Burn.loading || Burn.error === "") return;
            check(Date.now() - burnAt >= 2900, "1st refresh at ~3 s (" + (Date.now() - burnAt) + " ms)");
            eq(Burn.summary, null, "no summary");
            ps = Burn.providerState("claude");
            eq(ps.state, "unavailable", "claude: report failed");
            eq(ps.label, "Report failed", "failed report label");
            eq(ps.detail, "agent-burn failed (code 3)", "detail = CLI error");
            eq(ps.at, 0, "failed report: no reading");
            refreshWith("empty");   // empty home
            next();
            break;
        case 81:   // empty home
            if (!refreshed()) return;
            eq(Burn.dataState, "live", "live summary");
            ps = Burn.providerState("claude");
            eq(ps.state, "none", "claude: no usage, no subscription, no account");
            eq(ps.at, Burn.updatedAt, "none: time of the summary");
            eq(Burn.providerState("codex").state, "none", "codex absent");
            refreshWith("noauth");
            next();
            break;
        case 82:   // Claude usage without account (not signed in or offline), Codex with limits
            if (!refreshed()) return;
            ps = Burn.providerState("claude");
            eq(ps.state, "local", "claude: local usage");
            check(ps.detail.indexOf("not signed in") >= 0, "detail: not signed in or offline — " + ps.detail);
            eq(Burn.providerState("codex").state, "live", "codex live");
            refreshWith("installed");
            next();
            break;
        case 83:   // signed in, no log: account without usage
            if (!refreshed()) return;
            eq(Burn.providerState("claude").state, "live", "claude: account without usage → live");
            eq(Burn.providerState("codex").state, "none", "codex known from the archive only → not detected");
            finish();
            break;
        case 90:  // stuck CLI: summary and light reading killed by the watchdog
            if (Burn.error === "") return;
            var dt = Date.now() - burnAt;
            check(Burn.error.indexOf("within 10 s") >= 0, "timeout error: " + Burn.error);
            check(dt >= 13000 && dt <= 20000, "killed around 3 s + 10 s (" + dt + " ms)");
            check(Burn.summaryCached && Burn.dataState === "cached", "cached summary kept");
            eq(Burn.loading, false, "no run in progress");
            check(Burn.recentErrors.some(e => e.source === "quota" && e.msg.indexOf("within 10 s") >= 0), "light reading killed at 10 s");
            eq(Burn.account.observedAtMs, seedAt - 7200000, "last reading kept");
            finish();
            break;
        }
    }
}
