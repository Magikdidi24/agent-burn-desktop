pragma Singleton
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

// Agent Burn data (pill, popover, dashboard): agent-burn CLI reports, live Claude limits,
// daily archive and persisted quota readings. Reports stay as the CLI gives them: a missing
// amount is null, never 0.
Singleton {
    id: root

    property var summary: null
    property bool summaryCached: false   // reread from disk at startup, not yet replaced by a run
    property var harnesses: ({})
    property var harnessErrors: ({})   // { agent: message } of the last failed harness, cleared when it succeeds
    property var account: null   // most recent claudeAccount, persisted: stays displayed if the CLI fails
    property bool signInExpired: false   // renewal refused: sign-in expired, or network down (expired token)
    // Claude reading older than staleAfter, or sign-in expired: still displayed, but flagged stale.
    readonly property bool limitsStale: !!account && (signInExpired || now - (account.observedAtMs ?? 0) > staleAfter)
    property bool loading: sumProc.running || rangeProc.running || claudeProc.running || codexProc.running
    property string error: ""   // summary and CLI; harnesses have harnessErrors
    property var recentErrors: []   // last 20 failures { t, source, msg }, most recent last, without stdout
    property real updatedAt: 0
    property bool cliMissing: false
    // Remedy shown when the CLI is missing (BurnPopover); the desktop app sets its own.
    property string cliHint: "agent-burn CLI not found (~/.local/bin/agent-burn): rerun install.sh"
    // View texts exposed to screen readers: true in the desktop app (basic render loop on Linux).
    // False in the bar: on Qt 6.12, they crash Wayland's threaded render loop far more often.
    property bool accessibleText: false
    property bool dashboardOpen: false
    property string dashboardPage: "all"   // "all" or an agent
    property bool pendingForce: false   // refresh(true) requested during a run: replayed at its end
    property bool pendingRefresh: false   // refresh() during the range: summary launched at its end
    property var pendingHarness: ({})   // loadHarness() during the summary: { agent: force }, launched at its end
    property string range: "all"
    property var rangeCache: ({})   // { range: { at, data } }
    readonly property var rangeSummary: range === "all" ? summary : rangeCache[range]?.data ?? null
    property int refreshInterval: 300000   // background round in ms, set by the desktop app
    property int cliTimeoutMs: 120000   // CLI run killed beyond this, like the Mac app (lowered by the test suite)
    readonly property int cadence: Math.max(60000, refreshInterval)
    // Claude reading stale after 2 background rounds (one missed reading), 10 min at least.
    readonly property real staleAfter: Math.max(600000, 2 * cadence)
    // Cached: reread from disk, last summary failed, or older than the pill's hourly rhythm,
    // hourly summary duration included (cliTimeoutMs: its maximum timeout).
    readonly property string dataState: !summary ? "unavailable"
        : summaryCached || sumProc.failed || now - updatedAt > 3600000 + cadence + cliTimeoutMs ? "cached" : "live"
    // Tokens without any cost: pricing unavailable (offline, LiteLLM unreachable), the CLI counts $0.
    readonly property bool pricingMissing: (summary?.totals?.totalTokens ?? 0) > 0 && summary.totals.totalCost === 0

    property string bin: Quickshell.env("AGENT_BURN_BIN") || Quickshell.env("HOME") + "/.local/bin/agent-burn"
    // Passed to every run, never created: missing file = no config; the user's own configs
    // (./.agent-burn/, ~/.config/agent-burn/, ~/.claude/agent-burn.json: noCost, jq, offline) no longer apply.
    readonly property string cliConfig: Quickshell.dataPath("agent-burn-cli.json")
    // Clock of the derived values (past resets, "ago"): 10 s, stopped while idle.
    property real now: Date.now()

    // Daily archive: Claude Code deletes its logs older than 30 days, the archive keeps every day it has seen.
    property var history: ({})
    readonly property int historyDays: Object.keys(history).length
    property var samples: ({})   // quota readings { "<agent>:<key>": [{ t, used }] }, 8 days
    readonly property string dataDir: Quickshell.dataDir

    // Display currency: amounts stay in USD everywhere else (CLI, archive), money() converts them. Rates from
    // open.er-api.com (USD base, updated daily), requested only for another currency or when the currency list
    // opens: a USD user sends nothing. "": never requested (test suite).
    property string ratesUrl: "https://open.er-api.com/v6/latest/USD"
    property string currency: "USD"   // chosen code, kept in burn-fx.json
    property var rates: ({})   // { code: units per USD }, validated
    property real ratesAt: 0   // the provider's last update of these rates
    property real ratesNext: 0   // no request before this time
    property bool ratesLoading: false
    readonly property var currencies: Object.keys(Object.assign({ USD: 1 }, rates)).sort()
    // Without its rate (not loaded yet, dropped by the provider), the chosen currency shows as USD.
    readonly property string shownCurrency: rates.hasOwnProperty(currency) ? currency : "USD"
    readonly property real rate: shownCurrency === "USD" ? 1 : rates[shownCurrency]
    // Unambiguous symbols; any other code is written out ("CHF 12.34").
    readonly property var symbols: ({ USD: "$", EUR: "€", GBP: "£", JPY: "¥", CNY: "¥", INR: "₹", KRW: "₩",
                                      RUB: "₽", TRY: "₺", UAH: "₴", ILS: "₪", NGN: "₦", PHP: "₱", VND: "₫" })

    // Summary agents, plus those only the archive still knows (purged logs, at $0): the sum
    // of the per-agent rows stays equal to the archive total.
    readonly property var agents: {
        var cost = {};
        for (var day in history) for (var a in history[day].agents) cost[a] = 0;
        for (var e of summary?.agents ?? []) cost[e.agent] = e.totalCost ?? 0;
        return Object.keys(cost).sort((x, y) => cost[y] - cost[x]);
    }
    // Tightest window across all agents (bar pill).
    readonly property var tightest: {
        var best = null;
        for (var a of agents.concat((summary?.subscription?.agents ?? []).map(s => s.agent), account ? ["claude"] : []))
            for (var w of windows(a))
                if (!best || w.remaining < best.w.remaining) best = { agent: a, w: w };
        return best;
    }
    readonly property real remaining: tightest?.w.remaining ?? -1
    readonly property string remainingKey: tightest?.w.short ?? ""
    readonly property string remainingAgent: tightest?.agent ?? ""
    readonly property string remainingWindow: tightest?.w.key ?? ""

    readonly property var spans: ({ today: 0, "7d": 6, "30d": 29 })   // days before today
    readonly property var flags: ["--value", "--json", "--no-color"]
    // Known agents: name, brand color, harness = detailed CLI page (harness claude|codex).
    readonly property var providers: ({
        claude: { name: "Claude Code", color: "#d97757", harness: true },
        codex: { name: "Codex", color: "#10a37f", harness: true },
        cursor: { name: "Cursor", color: "#a855f7", harness: false },
        opencode: { name: "OpenCode", color: "#e5e5e5", harness: false },
        gemini: { name: "Gemini", color: "#4285f4", harness: false },
        pi: { name: "Pi", color: "#6b7280", harness: false },
        droid: { name: "Droid", color: "#6b7280", harness: false },
        openclaw: { name: "OpenClaw", color: "#6b7280", harness: false },
        kimi: { name: "Kimi", color: "#6b7280", harness: false },
        amp: { name: "Amp", color: "#6b7280", harness: false },
        qwen: { name: "Qwen", color: "#6b7280", harness: false }
    })
    readonly property var knownProviders: ["claude", "codex"]   // always listed (settings, diagnostics), even when missing
    readonly property var names: {
        var n = {};
        for (var a in providers) n[a] = providers[a].name;
        return n;
    }

    function agentEntry(agent) { return (summary?.agents ?? []).find(a => a.agent === agent) ?? null; }
    function subEntry(agent) { return (summary?.subscription?.agents ?? []).find(a => a.agent === agent) ?? null; }

    // Claude from the account (direct reading), the other agents from the summary's subscription.
    function windows(agent) {
        var out = [];
        function add(key, label, short, used, resetsAtMs, durationMin, startMs) {
            if (typeof used !== "number") return;
            // Past reset (stale reading): fresh window, which will start at the next request.
            if (resetsAtMs > 0 && resetsAtMs <= root.now) {
                startMs = resetsAtMs;
                resetsAtMs = 0;
                used = 0;
            }
            out.push({ key: key, label: label, short: short, used: used, remaining: Math.max(0, Math.min(100, 100 - used)),
                       resetsAtMs: resetsAtMs || 0, durationMin: durationMin,
                       startMs: resetsAtMs > 0 ? resetsAtMs - durationMin * 60000 : startMs || 0 });
        }
        var a = agent === "claude" ? account : null, e = agent === "claude" ? null : subEntry(agent);
        if (a) {
            add("session", "5-hour session", "5 h", a.sessionUsedPercent, a.sessionResetsAtMs, 300);
            add("weekly", "Week", "wk", a.weeklyUsedPercent, a.weeklyResetsAtMs, 10080);
            for (var s of a.scoped ?? [])
                add("scoped:" + s.name, s.name + " · week", s.name, s.usedPercent, s.resetsAtMs, 10080);
        }
        // Week already over (Codex logs older than 7 d, liveLimits still true): expired reading, session
        // included (no time, same age) → no window rather than the old % or a false 0%.
        if (e?.window?.elapsedMinutes >= 10080) return out;
        // shortcut: outside Claude, windows assumed to be 5 h and 7 d (CLI labels "5h"/"weekly"); read the label if an agent differs.
        if (e?.shortWindow) add("session", "5-hour session", "5 h", e.shortWindow.usedPercent, 0, 300);
        if (e?.window)
            add("weekly", "Week", "wk", e.window.usedPercent, updatedAt + (10080 - e.window.elapsedMinutes) * 60000, 10080);
        return out;
    }

    // Pace from the curve, not the average since the start: speed over the last day of a week (last hour
    // of a session), projected to the reset. ratio = that speed / the one ending at 0% left at the reset;
    // the verdict gets louder with it. Readings are interpolated, a window starts at 0%.
    function pace(agent, key) {
        var w = windows(agent).find(x => x.key === key);
        var r = { used: w ? w.used : null, elapsed: 0, projected: -1, ratio: -1, status: "unknown", title: "No data",
                  detail: "No reading for this limit yet.", exhaustAtMs: 0 };
        function set(status, title, detail) {
            r.status = status;
            r.title = title;
            r.detail = detail;
            return r;
        }
        if (!w) return r;
        var dur = w.durationMin * 60000, obs = agent === "claude" ? account.observedAtMs || now : updatedAt;   // time of the reading
        if (w.resetsAtMs) r.elapsed = Math.max(0, Math.min(1, (obs - w.startMs) / dur));
        if (w.used > 0 && w.remaining > 0 && r.elapsed > 0) {
            var look = Math.min(86400000, dur / 5), from = Math.max(w.startMs, obs - look);
            var pts = [{ t: w.startMs, used: 0 }].concat(quotaSamples(agent, key).filter(s => s.t > w.startMs && s.t < obs),
                                                          [{ t: obs, used: w.used }]);
            var i = pts.findIndex(s => s.t >= from), a = pts[Math.max(0, i - 1)], b = pts[i];
            var base = b.t > a.t ? a.used + (b.used - a.used) * (from - a.t) / (b.t - a.t) : b.used;
            // Window just started: a burst is not a trend yet. A full day for a week (its nights included), half an
            // hour for a session.
            var rate = Math.max(0, w.used - base) / Math.max(obs - from, dur > 86400000 ? look : look / 2);
            r.projected = w.used + rate * (w.resetsAtMs - obs);
            r.ratio = (r.projected - w.used) / w.remaining;
            if (r.ratio > 1) r.exhaustAtMs = obs + w.remaining / rate;
        }
        var margin = "Room to keep going";
        if (w.remaining <= 0)
            return set("danger", "Limit reached", "Resets " + (w.resetsAtMs ? until(w.resetsAtMs) : "at an unknown time") + ".");
        if (r.exhaustAtMs) {
            // Thresholds on the multiple as written (one decimal): the title never contradicts it.
            var short = dur <= 86400000, left = Math.max(60000, w.resetsAtMs - Math.max(now, obs)), x = Math.round(r.ratio * 10) / 10;
            return set(x >= 2 ? "danger" : "warn", x >= 2 ? "Pace way too fast" : x >= 1.3 ? "Pace too fast" : "Pace slightly too fast",
                       (x >= 1.3 ? x.toFixed(1) + "× the sustainable pace: runs" : "Runs") + " out ≈ "
                + new Date(r.exhaustAtMs).toLocaleString(Qt.locale("en_US"), short ? "HH:mm" : "ddd HH:mm")
                + ", " + span(w.resetsAtMs - r.exhaustAtMs) + " before the reset. Stay under "
                + (w.remaining * (short ? 3600000 : 86400000) / left).toFixed(1) + (short ? "%/h." : "%/day."));
        }
        if (r.projected >= 0) return set("good", margin, "At this pace, about " + Math.round(100 - r.projected) + "% left at the reset.");
        if (w.used > 0) return set("unknown", "Unknown pace", "Reset time unknown: no forecast.");
        return set("good", margin, "A forecast will appear as soon as this cycle has some usage.");
    }

    function quotaSamples(agent, key) {
        var w = windows(agent).find(x => x.key === key);
        if (!w) return [];
        var from = w.startMs || now - w.durationMin * 60000;
        return (samples[agent + ":" + key] ?? []).filter(s => s.t >= from);
    }

    // Agent state drawn only from the CLI's signals, never from the presence of files: the CLI says
    // neither "not signed in" nor "offline", and puts 0s for "unknown". at: time of the reading used.
    // Evaluated in bindings on every clock tick: reads only.
    function providerState(agent) {
        var claude = agent === "claude", a = claude ? account : null;
        var r = { state: "", label: "", detail: "", error: harnessErrors[agent] ?? "", at: 0 };
        function set(state, label, detail) {
            r.state = state;
            r.label = label;
            r.detail = detail;
            return r;
        }
        if (cliMissing) return set("unavailable", "CLI not found", cliHint);
        if (!summary) return error ? set("unavailable", "Report failed", error)
            : set("unknown", "Unknown", "No report from the agent-burn CLI yet.");
        r.at = a?.observedAtMs || updatedAt;
        // Also for an expired token without network (waking from sleep): the cause is not necessarily the sign-in.
        if (claude && signInExpired)
            return set("expired", "Check sign-in", "Limits refused: network unavailable, or sign-in expired (run claude, then /login).");
        if (!a && !agentEntry(agent) && !subEntry(agent))
            return set("none", "Not detected", "agent-burn finds neither usage nor a subscription for this agent.");
        if (a || windows(agent).length) {
            if (a ? !limitsStale : dataState === "live")
                return set("live", "Live", claude ? "Limits read from the Claude account, recent reading."
                    : "Limits from the latest agent-burn report (API or session logs).");
            return set("stale", "Stale reading", claude ? "Last known limits: no reading for more than "
                + Math.round(staleAfter / 60000) + " min."
                : "Last known limits, cached agent-burn report.");
        }
        return set("local", "Local usage", claude ? "Spend read from the logs; limits unavailable (not signed in or offline)."
            : "Spend read from the logs; limits missing or expired.");
    }
    function stateText(s) { return s === "live" ? "Live" : s === "cached" ? "Cached" : "Unavailable"; }

    // The archive wins over the summary: it keeps the cost of a day that dropped back to 0 offline.
    function dailySeries(agent) {
        var m = {};
        for (var d of (agent ? agentEntry(agent)?.daily : summary?.daily) ?? [])
            m[d.date] = { date: d.date, cost: d.cost, tokens: d.tokens };
        for (var day in history) {
            var e = agent ? history[day].agents[agent] : history[day];
            if (e) m[day] = { date: day, cost: e.cost, tokens: e.tokens };
        }
        return Object.keys(m).sort().map(k => m[k]);
    }

    function spendSince(agent, days) {
        var t = new Date(), from = iso(new Date(t.getFullYear(), t.getMonth(), t.getDate() - days + 1));
        return dailySeries(agent).reduce((s, d) => d.date >= from ? s + (d.cost ?? 0) : s, 0);
    }

    // The last n calendar days, today included, $0 without usage: a chart bounds its axis
    // to the 1st and last points, and a series only lists the active days.
    function lastDays(series, n) {
        var cost = {}, out = [];
        for (var d of series) cost[d.date] = d.cost;
        for (var i = n - 1; i >= 0; i--) {
            var t = new Date();
            t.setDate(t.getDate() - i);
            out.push({ date: iso(t), value: cost[iso(t)] ?? 0 });
        }
        return out;
    }

    // Only the summary gets the force env; harness and range follow it (sumProc.onExited). During the
    // range: launched at its end (rangeProc.onExited), never in parallel (429 from the usage API).
    function refresh(force) {
        if (sumProc.running || rangeProc.running) {
            pendingForce = pendingForce || !!force;
            pendingRefresh = pendingRefresh || rangeProc.running;
            return;
        }
        sumProc.forced = !!force;
        launch(sumProc, ["summary"].concat(flags), force ? { AGENT_BURN_FORCE_REFRESH: "1" } : {});
    }
    function poke() { if (Date.now() - updatedAt > 60000) refresh(false); }
    // force: without waiting 5 min, but never the force env (the summary's shared reading is reread).
    // During the summary: noted, launched at its end (sumProc.onExited).
    function loadHarness(agent, force) {
        var p = agent === "claude" ? claudeProc : agent === "codex" ? codexProc : null;   // CLI: claude|codex
        if (p && sumProc.running) pendingHarness[agent] = pendingHarness[agent] || !!force;
        else if (p && !p.running && (force || !harnesses[agent] || Date.now() - p.at > 300000))
            launch(p, ["harness", agent].concat(flags));
    }
    // Claude limits only (the Mac app's menu bar path): no log reading.
    function loadQuota() {
        if (!quotaProc.running && !sumProc.running)
            launch(quotaProc, ["harness", "claude", "--json", "--no-color"], { AGENT_BURN_QUOTA_ONLY: "1" });
    }
    // Already open (another workspace, under a fullscreen window): closed then reopened, Hyprland
    // remaps it to the foreground on the current workspace.
    function openDashboard(page) {
        dashboardPage = page;
        if (!dashboardOpen) dashboardOpen = true;
        else {
            dashboardOpen = false;
            Qt.callLater(() => root.dashboardOpen = true);
        }
    }
    function setRange(r) {
        if (r !== "all" && !spans.hasOwnProperty(r)) return;
        range = r;
        loadRange(false);
    }
    // During a summary: nothing in parallel (429 from the usage API), its exited relaunches the range (dashboard open).
    function loadRange(force) {
        var c = rangeCache[range];
        if (!spans.hasOwnProperty(range) || rangeProc.running || sumProc.running
            || (!force && c && Date.now() - c.at < 300000)) return;
        var t = new Date();
        rangeProc.key = range;
        launch(rangeProc, ["summary"].concat(flags, ["--since",
            iso(new Date(t.getFullYear(), t.getMonth(), t.getDate() - spans[range])).replace(/-/g, "")]));
    }
    // A code of the list (USD, or one with a rate), kept in burn-fx.json.
    function setCurrency(code) {
        if (!currencies.includes(code)) return;
        currency = code;
        saveTimer.start();
    }
    // One request at a time, none before ratesNext (the provider updates once a day).
    // shortcut: no timeout (QML's XMLHttpRequest has none), a request that never ends blocks the next ones
    // until restart; add an abort timer if that shows up.
    function loadRates() {
        if (!ratesUrl || ratesLoading || Date.now() < ratesNext) return;
        var x = new XMLHttpRequest();
        x.onreadystatechange = () => {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            root.ratesLoading = false;
            root.ratesDone(x.status, x.responseText);
        };
        ratesLoading = true;
        x.open("GET", ratesUrl);
        x.send();
    }
    // Only a valid answer replaces the rates (USD base, codes of 3 capital letters, finite positive rates);
    // otherwise the cached ones stay, failure in recentErrors.
    function ratesDone(status, text) {
        var d = null;
        try { d = JSON.parse(text); } catch (e) {}
        var r = status === 200 && d?.result === "success" && d.base_code === "USD" ? ratesOf(d.rates) : {};
        if (!Object.keys(r).length)
            return note("rates", "Exchange rates unavailable: "
                + (status === 200 ? "unreadable answer" : status ? "HTTP " + status : "network error"));
        var t = Date.now();
        rates = r;
        ratesAt = d.time_last_update_unix * 1000 || t;
        // At the provider's next update, kept between 1 h and 24 h from now (missing: 24 h).
        ratesNext = Math.min(t + 86400000, Math.max(t + 3600000, d.time_next_update_unix * 1000 || Infinity));
        saveTimer.start();
    }
    function ratesOf(o) {
        var r = {};
        for (var k in o)
            if (/^[A-Z]{3}$/.test(k) && Number.isFinite(o[k]) && o[k] > 0) r[k] = o[k];
        return r;
    }

    // USD amount in the shown currency; converted: already through fx() (chart axis, rounded in that currency).
    // No cents for small units (50 or more per USD: JPY, KRW, INR…).
    function money(v, converted) {
        if (v == null) return "—";
        return (symbols[shownCurrency] ?? shownCurrency + " ")
            + Number(converted ? v : fx(v)).toLocaleString(Qt.locale("en_US"), "f", rate >= 50 ? 0 : 2);
    }
    function fx(v) { return v == null ? null : v * rate; }
    // Tokens without a price (missing pricing): unknown cost, never $0.00.
    function priced(cost, tokens) { return tokens > 0 && cost === 0 ? null : cost; }
    function tokens(v) {
        if (v == null) return "—";
        return v >= 1e9 ? (v / 1e9).toFixed(2) + "B" : v >= 1e6 ? (v / 1e6).toFixed(2) + "M"
             : v >= 1e3 ? (v / 1e3).toFixed(1) + "K" : String(v);
    }
    function pct(v, digits) { return v == null ? "—" : Number(v).toFixed(digits ?? 0) + "%"; }
    // Tint of a pace() status.
    function tone(status) {
        return status === "good" ? Colors.good : status === "warn" ? Colors.warn
             : status === "danger" ? Colors.danger : Colors.muted;
    }
    function ago(ms) {
        if (!ms) return "never";
        var s = Math.floor((now - ms) / 1000);
        return s < 10 ? "just now" : s < 60 ? s + " s ago" : s < 3600 ? Math.floor(s / 60) + " min ago"
             : s < 86400 ? Math.floor(s / 3600) + " h ago" : Math.floor(s / 86400) + " d ago";
    }
    function until(ms) { return !ms ? "—" : ms <= now ? "now" : "in " + span(ms - now); }
    // "4 h 12 min", "2 d 3 h", "12 min".
    function span(ms) {
        var m = Math.floor(ms / 60000), d = Math.floor(m / 1440), h = Math.floor(m % 1440 / 60);
        if (d > 0) return d + " d" + (h > 0 ? " " + h + " h" : "");
        return h > 0 ? h + " h " + String(m % 60).padStart(2, "0") + " min" : Math.max(1, m) + " min";
    }
    function iso(d) { return d.toLocaleString(Qt.locale("C"), "yyyy-MM-dd"); }
    function agentName(a) { return providers.hasOwnProperty(a) ? providers[a].name : a; }
    function agentIcon(a) { return providers.hasOwnProperty(a) ? Qt.resolvedUrl("assets/burn/" + a + ".png") : ""; }
    function agentColor(a) { return providers.hasOwnProperty(a) ? providers[a].color : "#6b7280"; }

    // Variables that change the CLI's output: removed (null) unless this run asks for them.
    function launch(p, args, env) {
        p.launched = false;
        p.timedOut = false;
        p.exec({ command: [bin].concat(args, ["--config", cliConfig]),
                 environment: Object.assign({ AGENT_BURN_FORCE_REFRESH: null, AGENT_BURN_QUOTA_ONLY: null, LOG_LEVEL: null }, env) });
    }
    function note(source, msg) {
        recentErrors = recentErrors.concat([{ t: Date.now(), source: source, msg: msg }]).slice(-20);
    }
    // Cannot launch (no started): missing CLI. The light reading stays silent, like its other failures.
    function missing(p) {
        var msg = "agent-burn not found or not executable: " + bin;
        p.failed = true;
        if (p === quotaProc) return note("quota", msg);
        cliMissing = true;
        error = msg;
        note("cli", msg);
    }
    // Summary report: with agents[] (the AGENT_BURN_QUOTA_ONLY reading alone has none).
    function isReport(d) { return Array.isArray(d.agents); }
    // End of a run → JSON object (validated by check), or null with p.problem set (noted in recentErrors).
    // CLI errors on stderr: “Error: CliError("…")” with code 1, unknown option with code 2.
    function result(p, code, check) {
        cliMissing = false;
        p.failed = true;
        var lines = p.errorOutput.split("\n").map(l => l.trim()).filter(l => l);
        var line = lines.find(l => l.startsWith("Error: ")) ?? lines[0] ?? "";   // a WARN can precede the error
        var m = line.match(/^Error: CliError\("(.*)"\)$/);
        var detail = m ? m[1].replace(/\\(["\\])/g, "$1") : line;   // Rust Debug string: \" and \\ escaped
        if (detail.length > 160) detail = detail.slice(0, 159) + "…";
        if (p.timedOut) p.problem = "agent-burn did not respond within " + Math.round(cliTimeoutMs / 1000) + " s: try again in a moment.";
        else if (code === 2) p.problem = "Incompatible agent-burn CLI" + (detail ? ": " + detail : "");
        else if (code !== 0) p.problem = "agent-burn failed (code " + code + ")" + (detail ? ": " + detail : "");
        else {
            try {
                var d = JSON.parse(p.output);
                if (d && typeof d === "object" && (!check || check(d))) {
                    p.at = Date.now();
                    p.failed = false;
                    return d;
                }
            } catch (e) {}
            p.problem = "agent-burn returned an unreadable report.";
        }
        note(p.source, p.problem);
        return null;
    }
    function harnessDone(agent, p, code) {
        var d = result(p, code), e = Object.assign({}, harnessErrors);
        if (d) {
            var h = Object.assign({}, harnesses);
            h[agent] = d;
            harnesses = h;
            delete e[agent];
        } else e[agent] = p.problem;
        harnessErrors = e;
    }
    function setSummary(d) {
        now = Date.now();
        summary = d;
        summaryCached = false;
        updatedAt = now;
        error = "";
        signInExpired = d.claudeAccountStatus === "signInExpired";
        remember(d);
        for (var s of d.subscription?.agents ?? [])
            if (s.agent !== "claude") record(s.agent, now);
        merge(d);
    }
    // The report's Claude account, unless it is older than the one kept.
    function remember(d) {
        var a = d.claudeAccount;
        if (!a || (a.observedAtMs ?? 0) < (account?.observedAtMs ?? 0)) return;
        account = a;
        record("claude", a.observedAtMs ?? now);
    }
    // One reading per window, only if it is newer than the last one (same observedAtMs = duplicate).
    // On a plateau (same % as the last two), the last point moves forward: same plot, light file.
    function record(agent, t) {
        var s = {}, old = Date.now() - 8 * 86400000;
        for (var k in samples) {
            var kept = samples[k].filter(x => x.t >= old);
            if (kept.length) s[k] = kept;
        }
        for (var w of windows(agent)) {
            var l = s[agent + ":" + w.key] || (s[agent + ":" + w.key] = []), n = l.length;
            if (n && t <= l[n - 1].t) continue;
            if (n > 1 && l[n - 1].used === w.used && l[n - 2].used === w.used) l[n - 1].t = t;
            else l.push({ t: t, used: w.used });
        }
        samples = s;
        saveTimer.start();
    }
    // MetricsArchive rule: a full summary replaces the days it contains, the others stay.
    function merge(d) {
        var h = JSON.parse(JSON.stringify(history));
        for (var a of d.agents) for (var day of a.daily ?? []) {
            if (typeof day.cost !== "number" || !(day.cost >= 0)) continue;
            var e = h[day.date] || (h[day.date] = { cost: 0, tokens: 0, agents: {} }), old = e.agents[a.agent];
            // Cost dropped without a token drop, or $0 with tokens: missing pricing (network down
            // → bundled, partial prices), archived cost kept. Limitation: a LiteLLM price drop no longer
            // applies to days already archived.
            var keep = old?.cost > day.cost && day.tokens > 0 && (day.cost === 0 || day.tokens >= (old.tokens ?? 0));
            e.agents[a.agent] = { cost: keep ? old.cost : day.cost, tokens: day.tokens ?? old?.tokens ?? null };
            e.cost = 0;
            e.tokens = 0;
            for (var n in e.agents) {
                e.cost += e.agents[n].cost;
                e.tokens += e.agents[n].tokens ?? 0;
            }
        }
        history = h;
        saveTimer.start();
    }
    // Persisted file → object; unreadable: raw content copied to .bak before starting from scratch.
    function load(view, bak) {
        var raw = view.text();
        if (!raw) return {};
        try {
            var d = JSON.parse(raw);
            if (d && typeof d === "object" && !Array.isArray(d)) return d;
        } catch (e) {}
        bak.setText(raw);
        return {};
    }

    // Summary first (poke, before the window's own): the range follows at its end and rereads its shared reading.
    onDashboardOpenChanged: if (dashboardOpen) {
        poke();
        loadRange(false);
    }

    FileView { id: historyFile; path: Quickshell.dataPath("burn-history.json"); blockLoading: true }
    FileView { id: quotaFile; path: Quickshell.dataPath("burn-quota.json"); blockLoading: true }
    FileView { id: summaryFile; path: Quickshell.dataPath("burn-summary.json"); blockLoading: true }
    FileView { id: fxFile; path: Quickshell.dataPath("burn-fx.json"); blockLoading: true }
    // One FileView per copy: setText ignores content equal to what the view already saw, even from another path.
    FileView { id: historyBak; path: historyFile.path + ".bak"; preload: false; blockWrites: true }
    FileView { id: quotaBak; path: quotaFile.path + ".bak"; preload: false; blockWrites: true }
    FileView { id: summaryBak; path: summaryFile.path + ".bak"; preload: false; blockWrites: true }
    FileView { id: fxBak; path: fxFile.path + ".bak"; preload: false; blockWrites: true }
    Component.onCompleted: {
        history = load(historyFile, historyBak);
        var q = load(quotaFile, quotaBak);
        account = q.account ?? null;
        samples = q.samples ?? {};
        // Last successful summary, shown as "cached" until the 1st run: no merge, no replayed readings.
        var c = load(summaryFile, summaryBak);
        if (c.at > 0 && c.data && isReport(c.data)) {
            summary = c.data;
            updatedAt = c.at;
            summaryCached = true;
        }
        var f = load(fxFile, fxBak);
        rates = ratesOf(f.rates);
        ratesAt = Number(f.at) || 0;
        ratesNext = Number(f.next) || 0;
        currency = /^[A-Z]{3}$/.test(f.currency) ? f.currency : "USD";
    }
    // At most one write per second (NotifCenter pattern), atomic.
    Timer {
        id: saveTimer
        interval: 1000
        onTriggered: {
            historyFile.setText(JSON.stringify(root.history));
            quotaFile.setText(JSON.stringify({ account: root.account, samples: root.samples }));
            if (root.summary) summaryFile.setText(JSON.stringify({ at: root.updatedAt, data: root.summary }));
            fxFile.setText(JSON.stringify({ currency: root.currency, rates: root.rates, at: root.ratesAt, next: root.ratesNext }));
        }
    }

    // One CLI run: only one at a time per instance, JSON read at the end.
    component Cli: Process {
        property string source   // origin in recentErrors: summary, range, harness:<agent>, quota
        property real since
        property real at         // end of the last successful run
        property bool failed     // last run failed (launch, code, timeout, JSON)
        property string problem  // message of that last failure
        property bool launched   // started received: otherwise a launch failure, without exited
        property bool timedOut
        property alias output: out.text
        property alias errorOutput: err.text
        stdout: StdioCollector { id: out }
        stderr: StdioCollector { id: err }
        onStarted: {
            since = Date.now();
            launched = true;
        }
    }
    Cli {
        id: sumProc
        source: "summary"
        property bool forced
        onRunningChanged: if (!running && !launched) root.missing(sumProc)
        onExited: code => {
            var d = root.result(sumProc, code, root.isReport);
            if (d) root.setSummary(d);
            else root.error = sumProc.problem;
            if (root.pendingForce) {
                root.pendingForce = false;
                root.refresh(true);
                return;
            }
            // After the summary rather than in parallel: its shared reading (55 s) serves the next ones,
            // the usage API answers 429 to several processes at once. Harnesses requested during the run,
            // then those of the open dashboard.
            var w = root.pendingHarness;
            root.pendingHarness = {};
            for (var a of ["claude", "codex"])
                if (w.hasOwnProperty(a) || root.dashboardOpen && root.harnesses[a]) root.loadHarness(a, sumProc.forced || !!w[a]);
            if (root.dashboardOpen) root.loadRange(sumProc.forced);
        }
    }
    Cli {
        id: rangeProc
        source: "range"
        property string key
        onRunningChanged: if (!running && !launched) root.missing(rangeProc)
        onExited: code => {
            var d = root.result(rangeProc, code, root.isReport);
            if (d) {
                var c = Object.assign({}, root.rangeCache);
                c[key] = { at: Date.now(), data: d };
                root.rangeCache = c;
                root.remember(d);
                root.merge(d);   // fresher range days: cards and model table agree
            } else root.error = rangeProc.problem;
            // refresh() during the run: summary now, its end reloads the open dashboard's range.
            if (root.pendingRefresh) {
                var force = root.pendingForce;
                root.pendingRefresh = false;
                root.pendingForce = false;
                root.refresh(force);
            } else if (root.range !== key) root.loadRange(false);   // range changed during the run
        }
    }
    // The pill's light reading. Silent failure (recentErrors only): the last reading stays, flagged stale
    // after staleAfter. The reading only carries week and session: per-model limits and credits keep the summary's.
    Cli {
        id: quotaProc
        source: "quota"
        onRunningChanged: if (!running && !launched) root.missing(quotaProc)
        onExited: code => {
            var q = root.result(quotaProc, code, x => !!x.window && x.observedAt > 0);
            if (!q) return;
            var w = q.window, s = q.sessionWindow;
            // reset = time of the reading + remaining share of the window
            var end = x => q.observedAt + (100 - x.elapsedPercent) * x.windowMinutes * 600;
            var a = Object.assign({}, root.account, { observedAtMs: q.observedAt,
                                  weeklyUsedPercent: w.usedPercent, weeklyResetsAtMs: end(w) });
            if (s) Object.assign(a, { sessionUsedPercent: s.usedPercent, sessionResetsAtMs: end(s) });
            root.signInExpired = false;   // direct reading received: the sign-in works
            root.remember({ claudeAccount: a });
        }
    }
    Cli {
        id: claudeProc
        source: "harness:claude"
        onRunningChanged: if (!running && !launched) root.missing(claudeProc)
        onExited: code => root.harnessDone("claude", claudeProc, code)
    }
    Cli {
        id: codexProc
        source: "harness:codex"
        onRunningChanged: if (!running && !launched) root.missing(codexProc)
        onExited: code => root.harnessDone("codex", codexProc, code)
    }
    // Maximum timeout per run (cliTimeoutMs): process killed, the error comes from its exited.
    Timer {
        interval: 5000; repeat: true; running: root.loading || quotaProc.running
        onTriggered: {
            for (var p of [sumProc, rangeProc, claudeProc, codexProc, quotaProc])
                if (p.running && Date.now() - p.since > root.cliTimeoutMs) {
                    p.timedOut = true;
                    p.signal(9);
                }
        }
    }

    // 1st refresh 3 s after loading, unless a run is in progress or a summary succeeded less than 1 min ago
    // (dashboard open at launch: already launched by poke()); poke() on return from idle, then one
    // round per cadence. Pill on Claude's session or week: light reading, full summary (1 s
    // online, up to 1 min of CPU offline) at most every hour so that the archive sees every
    // day before the 30-day purge. Otherwise (other agent, per-model limit): summary every round.
    IdleMonitor {
        id: afk
        timeout: 300
        onIsIdleChanged: if (!isIdle) {
            root.now = Date.now();
            root.poke();
        }
    }
    Timer { interval: 3000; running: true; onTriggered: if (!root.loading && Date.now() - sumProc.at > 60000) root.refresh(false) }
    Timer {
        interval: root.cadence; repeat: true; running: !afk.isIdle
        onTriggered: root.remainingAgent === "claude" && !root.remainingWindow.startsWith("scoped:")
            && Date.now() - root.updatedAt < 3600000 ? root.loadQuota() : root.refresh(false)
    }
    Timer { interval: 10000; repeat: true; running: !afk.isIdle; onTriggered: root.now = Date.now() }
    // Currency other than USD: rates checked at startup, when it is chosen, then every hour (a request once expired).
    Timer {
        interval: 3600000; repeat: true; triggeredOnStart: true; running: root.currency !== "USD"
        onTriggered: root.loadRates()
    }

    IpcHandler {
        target: "burn"
        function refresh(): void { root.refresh(true); }
        function dashboard(): void { root.dashboardOpen = !root.dashboardOpen; }
    }
}
