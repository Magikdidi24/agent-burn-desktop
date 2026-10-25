import Quickshell
import Quickshell.Io
import QtQuick

// Test headless de Burn.qml (aucune fenêtre), sous qs et sous le shim de l'app Windows : mêmes résultats
// attendus. Fixtures de desktop/agent-burn/tests/fixtures servies par un faux CLI (fake/). Depuis ce dossier :
//   qs   : d=$(mktemp -d) && python3 -I fake/gen.py "$d" && AGENT_BURN_BIN="$d/agent-burn" timeout 25 qs -p "$PWD"
//   shim : python ../run_burn_suite.py   (python du venv PySide6 ; code 1 si un test échoue)
// BURN_TEST=corrupt : fichiers persistés illisibles → copie .bak.
// BURN_TEST=timeout : CLI bloqué → tué à 120 s (qs : timeout 150).
// Burn n'est référencé qu'après l'écriture des fichiers de départ (singleton créé au 1er accès).
Scope {
    id: t

    readonly property real day: 86400000
    readonly property string fake: String(Quickshell.env("AGENT_BURN_BIN")).replace(/\/[^\/]*$/, "")
    readonly property bool corrupt: Quickshell.env("BURN_TEST") === "corrupt"
    readonly property bool slow: Quickshell.env("BURN_TEST") === "timeout"
    readonly property string garbage: "{pas du json " + Date.now()   // unique : un vieux .bak ne masque rien
    property int step: 0
    property int passed: 0
    property int failed: 0
    property real stepAt: 0
    property real seedAt: 0
    property real burnAt: 0
    property real mark: 0

    // console.log est masqué par le niveau de log par défaut de qs : assert (ERROR) et info.
    function check(ok, msg) {
        if (ok) passed++;
        else failed++;
        console.assert(ok, "FAIL [étape " + step + "] " + msg);
    }
    function eq(a, b, msg) {
        check(a === b, msg + " : attendu " + JSON.stringify(b) + ", obtenu " + JSON.stringify(a));
    }
    function near(a, b, eps, msg) {
        check(typeof a === "number" && Math.abs(a - b) <= eps, msg + " : attendu ≈" + b + ", obtenu " + a);
    }
    function read(path) { rd.path = path; rd.reload(); return rd.text(); }
    function calls() { return read(fake + "/calls.log").split("\n").filter(l => l); }
    function summaryCalls() { return calls().filter(l => l.startsWith("summary") && l.indexOf("--since") < 0); }
    // Date locale à J+offset, séparateur au choix (indépendant de Burn).
    function date(offset, sep) {
        var d = new Date();
        d.setDate(d.getDate() + offset);
        var p = n => (n < 10 ? "0" : "") + n;
        return [d.getFullYear(), p(d.getMonth() + 1), p(d.getDate())].join(sep);
    }
    function next() { step++; stepAt = Date.now(); }
    function waited(ms) { return Date.now() - stepAt >= ms; }
    function finish() {
        console.info("RESULT: " + passed + " ok, " + failed + " échec(s)");
        step = -1;
        Qt.quit();
    }

    FileView { id: rd; preload: false; blockAllReads: true; printErrors: false }
    FileView { id: histSeed; path: Quickshell.dataPath("burn-history.json"); preload: false; blockWrites: true }
    FileView { id: quotaSeed; path: Quickshell.dataPath("burn-quota.json"); preload: false; blockWrites: true }
    FileView { id: mode; path: t.fake + "/mode"; preload: false; blockWrites: true }
    Process { id: ipc; command: ["qs", "ipc", "-p", Quickshell.shellDir, "call", "burn", "dashboard"] }

    Component.onCompleted: {
        var n = Date.now();
        seedAt = n;
        if (corrupt) {
            histSeed.setText(garbage);
            quotaSeed.setText(garbage);
        } else {
            histSeed.setText(JSON.stringify({ "2026-08-01": { cost: 5, tokens: 1000, agents: { claude: { cost: 5, tokens: 1000 } } } }));
            quotaSeed.setText(JSON.stringify({
                account: { sessionUsedPercent: 80, sessionResetsAtMs: n - 3600000, weeklyUsedPercent: 50,
                           weeklyResetsAtMs: n + 3 * day, scoped: [], observedAtMs: n - 7200000 },
                samples: { "claude:weekly": [{ t: n - 9 * day, used: 10 }, { t: n - 7200000, used: 50 }] }
            }));
        }
        next();
    }

    Timer {
        interval: 100; repeat: true; running: t.step > 0
        onTriggered: {
            try { t.tick(); } catch (e) { t.check(false, "exception : " + e + " " + e.stack); t.next(); }
            if (t.step > 0 && t.waited(t.slow ? 140000 : 8000)) { t.check(false, "délai dépassé"); t.finish(); }
        }
    }

    function tick() {
        var w, p, l;
        switch (step) {
        case 1:   // 1er accès à Burn : état persisté chargé, avant le 1er refresh (3 s)
            burnAt = Date.now();
            if (corrupt) {
                eq(Burn.historyDays, 0, "archive illisible → vide");
                eq(Burn.account, null, "quota illisible → pas de compte");
                eq(read(Quickshell.dataPath("burn-history.json.bak")), garbage, "archive brute copiée en .bak");
                eq(read(Quickshell.dataPath("burn-quota.json.bak")), garbage, "quota brut copié en .bak");
                finish();
                return;
            }
            if (slow) {
                mode.setText("slow\n");   // avant le 1er refresh (3 s)
                step = 19;
                next();
                return;
            }
            eq(Burn.money(null), "—", "money(null)");
            eq(Burn.money(undefined), "—", "money(undefined)");
            eq(Burn.money(831.8660224199998), "$831.87", "money");
            eq(Burn.money(1075.4374865599998), "$1,075.44", "money milliers");
            eq(Burn.money(0), "$0.00", "money(0)");
            eq(Burn.tokens(2005632865), "2.01B", "tokens B");
            eq(Burn.tokens(181976274), "181.98M", "tokens M");
            eq(Burn.tokens(21404), "21.4K", "tokens K");
            eq(Burn.tokens(950), "950", "tokens");
            eq(Burn.tokens(null), "—", "tokens(null)");
            eq(Burn.pct(75), "75 %", "pct");
            eq(Burn.pct(74.6), "75 %", "pct arrondi");
            eq(Burn.pct(null), "—", "pct(null)");
            var n = Burn.now;
            eq(Burn.ago(0), "jamais", "ago(0)");
            eq(Burn.ago(n), "à l'instant", "ago(now)");
            eq(Burn.ago(n - 12000), "il y a 12 s", "ago s");
            eq(Burn.ago(n - 180000), "il y a 3 min", "ago min");
            eq(Burn.ago(n - 7200000), "il y a 2 h", "ago h");
            eq(Burn.ago(n - 3 * day), "il y a 3 j", "ago j");
            eq(Burn.until(n + (4 * 3600 + 12 * 60 + 30) * 1000), "dans 4 h 12", "until h");
            eq(Burn.until(n + (4 * 3600 + 5 * 60) * 1000), "dans 4 h 05", "until h 0x");
            eq(Burn.until(n + (2 * 86400 + 3 * 3600 + 30) * 1000), "dans 2 j 3 h", "until j");
            eq(Burn.until(n + 12 * 60000 + 5000), "dans 12 min", "until min");
            eq(Burn.until(n - 1000), "maintenant", "until passé");
            eq(Burn.until(0), "—", "until(0)");
            eq(Burn.agentName("claude"), "Claude Code", "agentName");
            eq(Burn.agentName("opencode"), "OpenCode", "agentName opencode");
            eq(Burn.agentName("zz"), "zz", "agentName inconnu");
            check(String(Burn.agentIcon("claude")).endsWith("assets/burn/claude.png"), "agentIcon " + Burn.agentIcon("claude"));
            eq(Burn.agentIcon("zz"), "", "agentIcon inconnu");
            eq(String(Burn.agentColor("claude")), "#d97757", "agentColor");
            eq(String(Burn.agentColor("zz")), "#6b7280", "agentColor défaut");

            eq(Burn.summary, null, "pas encore de summary");
            eq(Burn.updatedAt, 0, "updatedAt jamais");
            eq(JSON.stringify(Burn.agents), '["claude"]', "agents : ceux de l'archive avant le 1er summary");
            eq(Burn.account.weeklyUsedPercent, 50, "compte persisté");
            w = Burn.windows("claude");
            eq(w.map(x => x.key).join(","), "session,weekly", "fenêtres du compte persisté");
            eq(w[0].used, 0, "session passée → réinitialisée");
            eq(w[0].remaining, 100, "session réinitialisée → 100 % restant");
            eq(w[0].resetsAtMs, 0, "session : prochain reset inconnu");
            eq(w[1].used, 50, "weekly used");
            eq(w[1].remaining, 50, "weekly remaining");
            eq(w[1].resetsAtMs, seedAt + 3 * day, "weekly resetsAtMs");
            eq(w[1].startMs, seedAt - 4 * day, "weekly startMs");
            eq(w[1].durationMin, 10080, "weekly durationMin");
            eq(Burn.windows("codex").length, 0, "codex sans abonnement");
            eq(Burn.remaining, 50, "remaining");
            eq(Burn.remainingKey, "sem.", "remainingKey");
            eq(Burn.remainingAgent, "claude", "remainingAgent");
            eq(Burn.remainingWindow, "weekly", "remainingWindow");
            p = Burn.pace("claude", "weekly");
            eq(p.status, "good", "pace persisté");
            eq(p.used, 50, "pace used");
            near(p.elapsed, 94 / 168, 1e-6, "pace elapsed (au relevé)");
            near(p.projected, 50 * 168 / 94, 1e-3, "pace projected");
            eq(p.exhaustAtMs, 0, "pas d'épuisement");
            eq(p.title, "De la marge pour continuer", "pace title");
            eq(Burn.pace("claude", "session").status, "good", "session réinitialisée → good");
            eq(Burn.pace("claude", "session").projected, -1, "session sans usage → pas de projection");
            eq(Burn.pace("claude", "nope").status, "unknown", "fenêtre inconnue");
            eq(Burn.pace("claude", "nope").used, null, "fenêtre inconnue : used null");
            l = Burn.quotaSamples("claude", "weekly");
            eq(l.length, 1, "échantillon hors fenêtre exclu");
            eq(l.length && l[0].used, 50, "échantillon persisté");
            eq(Burn.historyDays, 1, "archive persistée");
            eq(Burn.dailySeries("").length && Burn.dailySeries("")[0].date, "2026-08-01", "dailySeries archive");
            eq(Burn.dailySeries("codex").length, 0, "dailySeries agent absent");
            check(Burn.dataDir.length > 0, "dataDir");
            next();
            break;
        case 2:   // 1er summary (fixture A) à ~3 s
            if (Burn.updatedAt <= 0) return;
            check(Burn.updatedAt - burnAt >= 2900, "1er refresh à ~3 s (" + (Burn.updatedAt - burnAt) + " ms)");
            near(Burn.summary.totals.totalCost, 831.866, 0.001, "summary chargé");
            eq(JSON.stringify(Burn.agents), '["claude"]', "agents");
            eq(Burn.agentEntry("claude").totalTokens, 2005632865, "agentEntry");
            eq(Burn.agentEntry("zz"), null, "agentEntry absent");
            eq(Burn.subEntry("claude").plan, "Max 5×", "subEntry");
            eq(Burn.subEntry("zz"), null, "subEntry absent");
            eq(Burn.error, "", "pas d'erreur");
            eq(Burn.cliMissing, false, "CLI présent");
            w = Burn.windows("claude");
            eq(w.map(x => x.key).join(","), "session,weekly,scoped:Fable", "clés");
            eq(w.map(x => x.label).join(","), "Session 5 h,Semaine,Fable · semaine", "libellés");
            eq(w.map(x => x.short).join(","), "5 h,sem.,Fable", "courts");
            eq(w[0].used, 3, "session used");
            eq(w[0].durationMin, 300, "session 300 min");
            eq(w[0].startMs, w[0].resetsAtMs - 300 * 60000, "session startMs");
            eq(w[1].remaining, 25, "weekly remaining");
            eq(w[2].durationMin, 10080, "scoped hebdo");
            eq(Burn.remaining, 25, "remaining = fenêtre la plus contraignante");
            eq(Burn.remainingKey, "sem.", "remainingKey");
            eq(Burn.remainingWindow, "weekly", "remainingWindow");
            p = Burn.pace("claude", "weekly");
            eq(p.status, "warn", "épuisement avant reset → warn");
            near(p.projected, 102.122, 0.01, "projection (= estimate du CLI)");
            near(p.exhaustAtMs, w[1].resetsAtMs - 12569600, 60000, "épuisement ≈ 3 h 30 avant reset");
            eq(p.title, "Rythme un peu trop rapide", "title warn");
            check(p.detail.indexOf("%/jour") > 0, "detail : rythme conseillé par jour — " + p.detail);
            console.info("pace weekly : " + p.title + " — " + p.detail);
            p = Burn.pace("claude", "session");
            eq(p.status, "good", "session good");
            near(p.projected, 15, 0.01, "session projected");
            eq(Burn.historyDays, 16, "archive : 15 jours + 1 ancien");
            near(Burn.history[date(0, "-")].cost, 102.055, 0.001, "archive aujourd'hui");
            eq(Burn.history["2026-08-01"].cost, 5, "jour ancien conservé");
            l = Burn.dailySeries("");
            eq(l.length, 16, "dailySeries tous agents");
            check(l.every((d, i) => i === 0 || l[i - 1].date < d.date), "dailySeries trié");
            eq(Burn.dailySeries("claude").length, 16, "dailySeries claude");
            near(Burn.spendSince("", 7), 806.578, 0.001, "spendSince 7 j");
            near(Burn.spendSince("claude", 1), 102.055, 0.001, "spendSince aujourd'hui");
            eq(Burn.spendSince("codex", 7), 0, "spendSince agent absent");
            l = Burn.quotaSamples("claude", "weekly");
            eq(l.length, 2, "échantillon ajouté");
            check(l.length === 2 && l[0].t < l[1].t && l[1].used === 75, "échantillons triés");
            eq(Burn.quotaSamples("claude", "session").length, 1, "échantillon session");
            eq(Burn.quotaSamples("claude", "scoped:Fable").length, 1, "échantillon scoped");
            Burn.poke();              // summary frais : ignoré
            mark = Burn.updatedAt;
            Burn.refresh(true);
            Burn.refresh(false);      // déjà en cours : ignoré
            next();
            break;
        case 3:   // 2e summary (fixture B : vieux jours supprimés, aujourd'hui 150 $, hier à 0 $)
            if (Burn.updatedAt === mark || Burn.loading) return;
            l = summaryCalls();
            eq(l.length, 2, "poke et refresh concurrent ignorés");
            eq(l[0], "summary --value --json --no-color FORCE=0", "arguments comme l'app Mac");
            eq(l[1], "summary --value --json --no-color FORCE=1", "force → AGENT_BURN_FORCE_REFRESH=1");
            eq(Burn.historyDays, 16, "jours sortis des logs conservés");
            check(Burn.history[date(-25, "-")] !== undefined, "plus vieux jour conservé");
            near(Burn.history[date(0, "-")].cost, 150, 0.001, "jour présent remplacé");
            near(Burn.history[date(-1, "-")].cost, 489.289, 0.001, "coût 0 à tokens > 0 ignoré");
            eq(Burn.history[date(-1, "-")].tokens, 1199324996, "tokens d'hier");
            eq(Burn.summary.daily.length, 13, "summary remplacé");
            near(Burn.spendSince("", 7), 806.578 - 102.055 + 150, 0.001, "spendSince après fusion");
            eq(Burn.quotaSamples("claude", "weekly").length, 2, "même observedAtMs → pas de doublon");
            Burn.setRange("7d");
            eq(Burn.range, "7d", "range");
            eq(Burn.rangeSummary, null, "rangeSummary null pendant son 1er chargement");
            next();
            break;
        case 4:   // run --since
            if (Burn.rangeSummary === null) return;
            near(Burn.rangeSummary.totals.totalCost, 999.99, 0.001, "rangeSummary");
            l = calls();
            eq(l[l.length - 1], "summary --value --json --no-color --since " + date(-6, "") + " FORCE=0", "--since YYYYMMDD");
            mark = l.length;
            Burn.setRange("all");
            check(Burn.rangeSummary === Burn.summary, "all → summary");
            Burn.setRange("7d");      // en cache : pas de nouveau run
            near(Burn.rangeSummary.totals.totalCost, 999.99, 0.001, "rangeSummary en cache");
            Burn.setRange("bogus");
            eq(Burn.range, "7d", "plage inconnue ignorée");
            next();
            break;
        case 5:
            if (!waited(400)) return;
            eq(calls().length, mark, "plage en cache : pas de run");
            Burn.loadHarness("claude");
            Burn.loadHarness("cursor");   // CLI : claude|codex seulement
            next();
            break;
        case 6:
            if (!Burn.harnesses.claude) return;
            eq(Burn.harnesses.claude.plan, "Max 5×", "harness chargé");
            eq(Burn.harnesses.claude.window.windowMinutes, 10080, "harness window");
            mark = calls().length;
            Burn.loadHarness("claude");   // frais : ignoré
            next();
            break;
        case 7:   // fichiers persistés (sauvegarde différée 1 s)
            if (!waited(1500)) return;
            eq(calls().length, mark, "harness frais : pas de run");
            check(!calls().some(c => c.startsWith("harness cursor")), "harness cursor jamais lancé");
            var h = JSON.parse(read(Quickshell.dataPath("burn-history.json")));
            eq(Object.keys(h).length, 16, "archive écrite");
            near(h[date(-1, "-")].cost, 489.289, 0.001, "archive écrite : hier");
            eq(h["2026-08-01"].agents.claude.tokens, 1000, "archive écrite : jour ancien");
            var q = JSON.parse(read(Quickshell.dataPath("burn-quota.json")));
            eq(q.account.observedAtMs, Burn.account.observedAtMs, "compte écrit");
            eq(q.samples["claude:weekly"].length, 2, "échantillon > 8 j purgé");
            eq(q.samples["claude:session"].length, 1, "échantillons session écrits");
            mode.setText("fail\n");
            mark = Burn.updatedAt;
            Burn.refresh(false);
            next();
            break;
        case 8:
            if (Burn.loading || Burn.error === "") return;
            check(Burn.error.indexOf("code 3") >= 0, "erreur code de sortie : " + Burn.error);
            check(Burn.summary !== null && Burn.updatedAt === mark, "summary conservé sur échec");
            check(Burn.account !== null, "compte conservé sur échec");
            mode.setText("garbage\n");
            Burn.refresh(false);
            next();
            break;
        case 9:
            if (Burn.loading || Burn.error.indexOf("code 3") >= 0) return;
            check(Burn.error.indexOf("illisible") >= 0, "erreur JSON : " + Burn.error);
            eq(Burn.cliMissing, false, "CLI présent");
            Burn.bin = "/nonexistent/agent-burn";
            Burn.refresh(false);
            next();
            break;
        case 10:
            if (!Burn.cliMissing) return;
            check(Burn.error.indexOf("introuvable") >= 0, "erreur CLI absent : " + Burn.error);
            Burn.bin = Quickshell.env("AGENT_BURN_BIN");
            mode.setText("ok\n");
            Burn.refresh(false);
            next();
            break;
        case 11:
            if (Burn.cliMissing || Burn.loading || Burn.updatedAt === mark) return;
            eq(Burn.error, "", "erreur effacée au succès");
            eq(Burn.dashboardOpen, false, "dashboard fermé");
            // Rejoués depuis exited : running doit y être déjà faux (sinon rien n'est relancé).
            mark = summaryCalls().length;
            Burn.refresh(false);
            Burn.refresh(true);
            next();
            break;
        case 12:
            if (Burn.loading || !waited(1500)) return;
            eq(JSON.stringify(summaryCalls().slice(mark)), JSON.stringify(["summary --value --json --no-color FORCE=0",
                "summary --value --json --no-color FORCE=1"]), "refresh(true) pendant un run : rejoué forcé à sa fin");
            eq(Burn.pendingForce, false, "pendingForce consommé");
            mark = calls().length;
            Burn.setRange("30d");
            Burn.setRange("today");   // pendant le run --since des 30 jours
            next();
            break;
        case 13:
            if (Burn.loading || !waited(1500)) return;
            eq(JSON.stringify(calls().slice(mark)), JSON.stringify(["summary --value --json --no-color --since " + date(-29, "")
                + " FORCE=0", "summary --value --json --no-color --since " + date(0, "") + " FORCE=0"]),
               "plage changée pendant un run : relancée sur la nouvelle à sa fin");
            check(Burn.rangeSummary !== null, "rangeSummary de la nouvelle plage");
            ipc.running = true;
            next();
            break;
        case 14:
            if (!Burn.dashboardOpen) return;
            check(true, "IPC burn dashboard");
            finish();
            break;
        case 20:  // CLI bloqué : tué par le watchdog
            if (Burn.error === "") return;
            var dt = Date.now() - burnAt;
            check(Burn.error.indexOf("120 s") >= 0, "erreur de délai : " + Burn.error);
            check(dt >= 123000 && dt <= 133000, "tué vers 3 s + 120 s (" + dt + " ms)");
            eq(Burn.summary, null, "pas de summary");
            eq(Burn.loading, false, "plus de run en cours");
            finish();
            break;
        }
    }
}
