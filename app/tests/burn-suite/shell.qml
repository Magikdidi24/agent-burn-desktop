import Quickshell
import Quickshell.Io
import QtQuick

// Test headless de Burn.qml (aucune fenêtre), sous qs et sous le shim de l'app de bureau : mêmes résultats
// attendus. Fixtures de desktop/agent-burn/tests/fixtures servies par un faux CLI (fake/). Depuis ce dossier :
//   qs   : d=$(mktemp -d) && python3 -I fake/gen.py "$d" && AGENT_BURN_BIN="$d/agent-burn" timeout 25 qs -p "$PWD"
//          (XDG_* vers un dossier jetable, XDG_RUNTIME_DIR court pour l'IPC ; qs sort en 0 même en échec :
//          lire la ligne RESULT)
//   shim : python ../run_burn_suite.py   (python du venv PySide6 ; code 1 si un test échoue)
// BURN_TEST=corrupt : fichiers persistés illisibles → copie .bak, puis états des agents sans compte.
// BURN_TEST=timeout : CLI bloqué → summary et relevé léger tués à 120 s (qs : timeout 150).
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
    function rawCalls() { return read(fake + "/calls.log").split("\n").filter(l => l); }
    // --config sur chaque appel (vérifié à la fin) : retiré pour comparer le reste.
    function calls() { return rawCalls().map(l => l.replace(" --config " + Burn.cliConfig, "")); }
    function summaryCalls() { return calls().filter(l => l.startsWith("summary") && l.indexOf("--since") < 0); }
    function last() { return Burn.recentErrors[Burn.recentErrors.length - 1] ?? {}; }
    // Date locale à J+offset, séparateur au choix (indépendant de Burn).
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
        console.info("RESULT: " + passed + " ok, " + failed + " échec(s)");
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
            // Dernier summary réussi d'une session précédente : maison vide (rien d'installé).
            sumSeed.setText(JSON.stringify({ at: n - 3 * 3600000, data: JSON.parse(read(fake + "/summary-empty.json")) }));
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
        var w, p, l, ps, u;
        switch (step) {
        case 1:   // 1er accès à Burn : état persisté chargé, avant le 1er refresh (3 s)
            burnAt = Date.now();
            if (corrupt) {
                eq(Burn.historyDays, 0, "archive illisible → vide");
                eq(Burn.account, null, "quota illisible → pas de compte");
                eq(read(Quickshell.dataPath("burn-history.json.bak")), garbage, "archive brute copiée en .bak");
                eq(read(Quickshell.dataPath("burn-quota.json.bak")), garbage, "quota brut copié en .bak");
                eq(read(Quickshell.dataPath("burn-summary.json.bak")), garbage, "summary brut copié en .bak");
                eq(Burn.summary, null, "summary illisible → aucun");
                eq(Burn.summaryCached, false, "rien en cache");
                eq(Burn.dataState, "unavailable", "dataState sans summary");
                eq(Burn.stateText(Burn.dataState), "Indisponible", "stateText unavailable");
                ps = Burn.providerState("claude");
                eq(ps.state, "unknown", "claude avant le 1er rapport");
                eq(ps.label, "Inconnu", "label unknown");
                eq(ps.at, 0, "unknown : aucun relevé");
                mode.setText("fail\n");   // 1er summary du minuteur : en échec
                step = 79;
                next();
                return;
            }
            if (slow) {
                mode.setText("slow\n");   // avant le 1er refresh (3 s)
                Burn.loadQuota();          // relevé léger bloqué lui aussi
                step = 89;
                next();
                return;
            }
            eq(Burn.money(null), "—", "money(null)");
            eq(Burn.money(undefined), "—", "money(undefined)");
            eq(Burn.money(831.8660224199998), "$831.87", "money");
            eq(Burn.money(1075.4374865599998), "$1,075.44", "money milliers");
            eq(Burn.money(0), "$0.00", "money(0)");
            eq(Burn.priced(0, 5), null, "priced : tokens sans prix → inconnu");
            eq(Burn.priced(0, 0), 0, "priced : rien d'utilisé → 0");
            eq(Burn.priced(1.5, 10), 1.5, "priced : coût gardé");
            eq(Burn.priced(null, 10), null, "priced(null)");
            eq(Burn.money(Burn.priced(0, 5)), "—", "jamais $0.00 sans prix");
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
            eq(String(Burn.agentColor("codex")), "#10a37f", "agentColor codex");
            eq(String(Burn.agentColor("pi")), "#6b7280", "agentColor sans marque");
            eq(String(Burn.agentColor("zz")), "#6b7280", "agentColor défaut");
            eq(Object.keys(Burn.providers).join(","), "claude,codex,cursor,opencode,gemini,pi,droid,openclaw,kimi,amp,qwen",
               "registre des fournisseurs");
            eq(Object.keys(Burn.providers).filter(a => Burn.providers[a].harness).join(","), "claude,codex", "harness : claude|codex");
            eq(Burn.names.qwen, "Qwen", "names lu du registre");
            eq(JSON.stringify(Burn.knownProviders), '["claude","codex"]', "knownProviders");
            eq(Burn.stateText("live"), "En direct", "stateText live");
            eq(Burn.stateText("cached"), "En cache", "stateText cached");
            eq(Burn.stateText("unavailable"), "Indisponible", "stateText unavailable");
            eq(Burn.cliHint, "CLI agent-burn introuvable (~/.local/bin/agent-burn) : relance install.sh", "cliHint par défaut");
            eq(Burn.cliConfig, Quickshell.dataPath("agent-burn-cli.json"), "cliConfig dans le dossier de données");
            eq(Burn.refreshInterval, 300000, "cadence par défaut 5 min");
            eq(Burn.accessibleText, false, "textes non exposés par défaut (barre : boucle de rendu threaded)");

            check(Burn.summary !== null && Burn.summary.agents.length === 0, "summary en cache relu au démarrage");
            eq(Burn.summaryCached, true, "summaryCached");
            eq(Burn.updatedAt, seedAt - 3 * 3600000, "updatedAt du summary en cache");
            eq(Burn.dataState, "cached", "dataState : en cache");
            eq(Burn.stateText(Burn.dataState), "En cache", "stateText du summary en cache");
            eq(Burn.pricingMissing, false, "maison vide : pas de tarif manquant");
            eq(Burn.recentErrors.length, 0, "aucun échec");
            eq(JSON.stringify(Burn.harnessErrors), "{}", "aucun échec de harness");
            eq(JSON.stringify(Burn.agents), '["claude"]', "agents : ceux de l'archive avant le 1er summary");
            eq(Burn.account.weeklyUsedPercent, 50, "compte persisté");
            ps = Burn.providerState("claude");
            eq(ps.state, "stale", "claude : compte persisté vieux de 2 h");
            eq(ps.label, "Relevé ancien", "label stale");
            eq(ps.at, seedAt - 7200000, "at = relevé du compte");
            eq(ps.error, "", "claude sans erreur");
            ps = Burn.providerState("codex");
            eq(ps.state, "none", "codex : ni usage ni abonnement");
            eq(ps.label, "Non détecté", "label none");
            eq(ps.at, seedAt - 3 * 3600000, "at = summary en cache");
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
            eq(Burn.historyDays, 1, "archive persistée, summary en cache non fusionné");
            eq(Burn.dailySeries("").length && Burn.dailySeries("")[0].date, "2026-08-01", "dailySeries archive");
            eq(Burn.dailySeries("codex").length, 0, "dailySeries agent absent");
            check(Burn.dataDir.length > 0, "dataDir");
            // Dashboard ouvert au lancement : summary tout de suite, harness demandé pendant qu'il tourne.
            mode.setText("delay\n");
            Burn.poke();
            Burn.loadHarness("claude");
            next();
            break;
        case 2:
            if (calls().length === 0) return;
            check(Burn.loading && !calls().some(c => c.startsWith("harness")), "harness différé pendant le summary : " + calls());
            next();
            break;
        case 3:   // 1er summary (fixture A) puis le harness différé ; minuteur des 3 s passé
            if (Burn.summaryCached || !Burn.harnesses.claude || Burn.loading || Date.now() - burnAt < 3600) return;
            mode.setText("ok\n");
            eq(JSON.stringify(calls()), JSON.stringify(["summary --value --json --no-color FORCE=0",
                "harness claude --value --json --no-color FORCE=0"]), "un seul summary au démarrage, puis le harness");
            near(Burn.summary.totals.totalCost, 831.866, 0.001, "summary chargé");
            eq(Burn.summaryCached, false, "summary en direct");
            eq(Burn.dataState, "live", "dataState live");
            eq(Burn.pricingMissing, false, "tarifs présents");
            ps = Burn.providerState("claude");
            eq(ps.state, "live", "claude en direct");
            eq(ps.label, "En direct", "label live");
            eq(ps.at, Burn.account.observedAtMs, "at = relevé du compte");
            eq(Burn.providerState("codex").state, "none", "codex toujours absent");
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
        case 4:   // 2e summary (fixture B : vieux jours supprimés, aujourd'hui 150 $, hier à 0 $)
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
        case 5:   // run --since
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
        case 6:
            if (!waited(400)) return;
            eq(calls().length, mark, "plage en cache : pas de run");
            Burn.loadHarness("claude");   // chargé à l'étape 3, frais : ignoré
            Burn.loadHarness("cursor");   // CLI : claude|codex seulement
            next();
            break;
        case 7:
            if (!Burn.harnesses.claude) return;
            eq(Burn.harnesses.claude.plan, "Max 5×", "harness chargé");
            eq(Burn.harnesses.claude.window.windowMinutes, 10080, "harness window");
            mark = calls().length;
            Burn.loadHarness("claude");   // frais : ignoré
            next();
            break;
        case 8:   // fichiers persistés (sauvegarde différée 1 s)
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
            var s = JSON.parse(read(Quickshell.dataPath("burn-summary.json")));
            eq(s.at, Burn.updatedAt, "summary écrit : instant du run");
            eq(s.data.daily.length, 13, "summary écrit : le dernier (B)");
            mode.setText("fail\n");
            mark = Burn.updatedAt;
            Burn.refresh(false);
            next();
            break;
        case 9:
            if (Burn.loading || Burn.error === "") return;
            eq(Burn.error, "agent-burn a échoué (code 3)", "code de sortie, stderr vide");
            check(Burn.summary !== null && Burn.updatedAt === mark, "summary conservé sur échec");
            check(Burn.account !== null, "compte conservé sur échec");
            eq(Burn.dataState, "cached", "dernier summary en échec → en cache");
            eq(last().source, "summary", "recentErrors : source");
            eq(last().msg, Burn.error, "recentErrors : message");
            check(last().t > 0 && Date.now() - last().t < 5000, "recentErrors : instant");
            mode.setText("err1\n");
            Burn.refresh(false);
            next();
            break;
        case 10:   // code 1 : WARN puis Error: CliError("…") (CLAUDE_CONFIG_DIR invalide, sortie réelle)
            if (Burn.loading || Burn.error.indexOf("code 1") < 0) return;
            var head = "agent-burn a échoué (code 1) : ";
            check(Burn.error.startsWith(head + "No valid Claude data directories found in CLAUDE_CONFIG_DIR."),
                  "détail : ligne Error: déballée, WARN ignoré — " + Burn.error);
            eq(Burn.error.length - head.length, 160, "détail tronqué à 160 caractères");
            check(Burn.error.endsWith("…") && Burn.error.indexOf("CliError") < 0, "détail tronqué et déballé");
            mode.setText("err2\n");
            Burn.refresh(false);
            next();
            break;
        case 11:   // code 2 : option inconnue (CLI d'une autre version)
            if (Burn.loading || Burn.error.indexOf("incompatible") < 0) return;
            eq(Burn.error, "CLI agent-burn incompatible : Unknown summary option '--frobnicate'", "code 2 : 1re ligne du stderr");
            mode.setText("garbage\n");
            Burn.refresh(false);
            next();
            break;
        case 12:
            if (Burn.loading || Burn.error.indexOf("illisible") < 0) return;
            check(Burn.error.indexOf("illisible") >= 0, "erreur JSON : " + Burn.error);
            eq(Burn.cliMissing, false, "CLI présent");
            check(JSON.stringify(Burn.recentErrors).indexOf("pas du json") < 0, "recentErrors sans le stdout");
            refreshWith("leak");
            next();
            break;
        case 13:   // AGENT_BURN_QUOTA_ONLY hérité : JSON valide sans agents[]
            if (!refreshed()) return;
            eq(Burn.error, "Rapport illisible renvoyé par agent-burn.", "rapport sans agents[] → illisible");
            eq(Burn.summary.daily.length, 13, "summary B gardé");
            Burn.bin = "/nonexistent/agent-burn";
            Burn.refresh(false);
            next();
            break;
        case 14:
            if (!Burn.cliMissing) return;
            check(Burn.error.indexOf("introuvable") >= 0, "erreur CLI absent : " + Burn.error);
            ps = Burn.providerState("claude");
            eq(ps.state, "unavailable", "CLI absent → unavailable");
            eq(ps.label, "CLI introuvable", "label unavailable");
            eq(ps.detail, Burn.cliHint, "detail = remède de l'hôte");
            eq(ps.at, 0, "unavailable : aucun relevé");
            eq(last().source, "cli", "recentErrors : CLI absent");
            eq(Burn.dataState, "cached", "CLI absent → en cache");
            Burn.bin = Quickshell.env("AGENT_BURN_BIN");
            mode.setText("ok\n");
            mark = Burn.updatedAt;
            Burn.refresh(false);
            next();
            break;
        case 15:
            if (Burn.cliMissing || Burn.loading || Burn.updatedAt === mark) return;
            eq(Burn.error, "", "erreur effacée au succès");
            eq(Burn.dataState, "live", "succès → en direct");
            u = Burn.updatedAt;
            Burn.refreshInterval = 1000;   // < 1 min : compté 1 min
            Burn.now = Date.now();
            Burn.updatedAt = Burn.now - 3600000 - 190000;
            eq(Burn.dataState, "cached", "plus vieux qu'1 h + cadence (plancher 1 min) + 2 min de run → en cache");
            Burn.updatedAt = Burn.now - 3600000 - 170000;
            eq(Burn.dataState, "live", "1 h 2 min 50 s : summary horaire en cours, encore en direct");
            Burn.refreshInterval = 300000;
            Burn.updatedAt = u;
            // Relevé Claude ancien après 2 tours de fond, 10 min au moins.
            var acc = Burn.account;
            Burn.account = Object.assign({}, acc, { observedAtMs: Burn.now - 11 * 60000 });
            eq(Burn.limitsStale, true, "cadence 5 min : relevé de 11 min ancien");
            eq(Burn.providerState("claude").detail, "Dernières limites connues : aucun relevé depuis plus de 10 min.",
               "détail : seuil de 10 min");
            Burn.refreshInterval = 900000;
            eq(Burn.limitsStale, false, "cadence 15 min : relevé de 11 min encore récent");
            Burn.account = Object.assign({}, acc, { observedAtMs: Burn.now - 31 * 60000 });
            eq(Burn.limitsStale, true, "cadence 15 min : ancien après 2 tours");
            eq(Burn.providerState("claude").detail, "Dernières limites connues : aucun relevé depuis plus de 30 min.",
               "détail : seuil de 2 tours");
            Burn.refreshInterval = 300000;
            Burn.account = acc;
            eq(Burn.limitsStale, false, "relevé récent rétabli");
            eq(Burn.dashboardOpen, false, "dashboard fermé");
            // Rejoués depuis exited : running doit y être déjà faux (sinon rien n'est relancé).
            mark = summaryCalls().length;
            Burn.refresh(false);
            Burn.refresh(true);
            next();
            break;
        case 16:
            if (Burn.loading || !waited(1500)) return;
            eq(JSON.stringify(summaryCalls().slice(mark)), JSON.stringify(["summary --value --json --no-color FORCE=0",
                "summary --value --json --no-color FORCE=1"]), "refresh(true) pendant un run : rejoué forcé à sa fin");
            eq(Burn.pendingForce, false, "pendingForce consommé");
            mark = calls().length;
            Burn.setRange("30d");
            Burn.setRange("today");   // pendant le run --since des 30 jours
            next();
            break;
        case 17:
            if (Burn.loading || !waited(1500)) return;
            eq(JSON.stringify(calls().slice(mark)), JSON.stringify(["summary --value --json --no-color --since " + date(-29, "")
                + " FORCE=0", "summary --value --json --no-color --since " + date(0, "") + " FORCE=0"]),
               "plage changée pendant un run : relancée sur la nouvelle à sa fin");
            check(Burn.rangeSummary !== null, "rangeSummary de la nouvelle plage");
            refreshWith("codex");
            next();
            break;
        case 18:   // Claude + Codex (limites Codex des logs récents)
            if (!refreshed()) return;
            check(Burn.agents.indexOf("codex") >= 0, "codex dans les agents");
            w = Burn.windows("codex");
            eq(w.map(x => x.key).join(","), "session,weekly", "fenêtres codex");
            eq(w.map(x => x.used).join(","), "12,34", "codex used");
            near(w[1].resetsAtMs, Burn.updatedAt + (10080 - Burn.subEntry("codex").window.elapsedMinutes) * 60000, 1, "codex reset hebdo");
            ps = Burn.providerState("codex");
            eq(ps.state, "live", "codex en direct");
            eq(ps.at, Burn.updatedAt, "codex at = summary");
            eq(ps.error, "", "codex sans erreur");
            eq(Burn.providerState("claude").state, "live", "claude toujours en direct");
            eq(Burn.quotaSamples("codex", "weekly").length, 1, "relevé codex enregistré");
            Burn.loadHarness("codex");   // pas de fixture : échec
            next();
            break;
        case 19:
            if (Burn.loading || !Burn.harnessErrors.codex) return;
            eq(Burn.harnessErrors.codex, 'agent-burn a échoué (code 1) : pas de fixture "harness-codex.json" dans C:\\fake',
               "erreur harness : CliError déballée, \\\" et \\\\ rétablis");
            eq(Burn.error, "", "erreur harness hors de l'erreur globale");
            eq(Burn.providerState("codex").error, Burn.harnessErrors.codex, "erreur sur l'agent concerné");
            eq(Burn.providerState("claude").error, "", "les autres agents restent propres");
            eq(last().source, "harness:codex", "recentErrors : harness");
            eq(Burn.harnesses.codex, undefined, "pas de harness codex");
            codexHarness.setText(read(fake + "/harness-codex.json.next"));
            Burn.loadHarness("codex");
            next();
            break;
        case 20:
            if (Burn.loading || !Burn.harnesses.codex) return;
            eq(Burn.harnesses.codex.plan, "Plus", "harness codex chargé");
            check(!Burn.harnessErrors.hasOwnProperty("codex"), "erreur codex effacée au succès");
            eq(Burn.providerState("codex").error, "", "codex propre");
            refreshWith("codex-stale");
            next();
            break;
        case 21:   // logs Codex de 9-10 jours : liveLimits vrai, semaine écoulée
            if (!refreshed()) return;
            eq(Burn.windows("codex").length, 0, "relevé expiré : ni semaine ni session");
            eq(Burn.subEntry("codex").window.usedPercent, 91, "le rapport garde le vieux relevé");
            ps = Burn.providerState("codex");
            eq(ps.state, "local", "codex : usage sans limites");
            eq(ps.label, "Usage local", "label local");
            eq(Burn.remainingAgent, "claude", "pill : jamais le vieux % de Codex");
            refreshWith("expired");
            next();
            break;
        case 22:   // connexion expirée (ou jeton expiré sans réseau) et tarifs embarqués à 0 $
            if (!refreshed()) return;
            eq(Burn.signInExpired, true, "signInExpired");
            eq(Burn.limitsStale, true, "limites signalées anciennes");
            ps = Burn.providerState("claude");
            eq(ps.state, "expired", "claude : connexion à vérifier");
            eq(ps.label, "Connexion à vérifier", "label expired");
            check(ps.detail.indexOf("réseau") >= 0 && ps.detail.indexOf("/login") >= 0, "detail : réseau ou /login — " + ps.detail);
            eq(ps.at, Burn.account.observedAtMs, "expired : relevé gardé");
            eq(Burn.pricingMissing, true, "tokens à 0 $ → tarifs manquants");
            eq(Burn.priced(Burn.summary.totals.totalCost, Burn.summary.totals.totalTokens), null, "total sans prix → inconnu");
            eq(Burn.dataState, "live", "données fraîches malgré les tarifs");
            Burn.loadQuota();
            next();
            break;
        case 23:   // relevé léger (AGENT_BURN_QUOTA_ONLY)
            if (Burn.account.weeklyUsedPercent !== 3) return;
            var r = JSON.parse(read(fake + "/quota-claude.json"));
            eq(calls()[calls().length - 1], "harness claude --json --no-color FORCE=0 QUOTA=1", "relevé léger : arguments et env");
            eq(Burn.account.observedAtMs, r.observedAt, "relevé daté");
            near(Burn.account.weeklyResetsAtMs, r.observedAt + (100 - r.window.elapsedPercent) * r.window.windowMinutes * 600, 1, "reset hebdo");
            eq(Burn.account.sessionUsedPercent, 22, "session du relevé");
            eq(Burn.signInExpired, false, "relevé direct : connexion rétablie");
            eq(Burn.providerState("claude").state, "live", "claude de nouveau en direct");
            mode.setText("fail\n");
            mark = Burn.recentErrors.length;
            Burn.loadQuota();
            next();
            break;
        case 24:   // relevé léger en échec : muet
            if (Burn.recentErrors.length === mark) return;
            eq(last().source, "quota", "échec noté");
            eq(last().msg, "agent-burn a échoué (code 3)", "message du relevé");
            eq(Burn.error, "", "UI muette");
            eq(Burn.account.weeklyUsedPercent, 3, "dernier relevé gardé");
            mode.setText("ok\n");
            Burn.bin = "/nonexistent/agent-burn";
            mark = Burn.recentErrors.length;
            Burn.loadQuota();
            next();
            break;
        case 25:   // relevé léger sans CLI : muet aussi, cliMissing laissé au summary
            if (Burn.recentErrors.length === mark) return;
            eq(last().source, "quota", "lancement impossible noté");
            check(last().msg.indexOf("introuvable") >= 0, "message : " + last().msg);
            eq(Burn.cliMissing, false, "cliMissing intact");
            eq(Burn.error, "", "UI muette");
            Burn.bin = Quickshell.env("AGENT_BURN_BIN");
            // Dashboard ouvert pendant un summary : plage chargée à sa fin, jamais en parallèle (429).
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
                  "plage différée pendant le summary : " + calls().slice(mark));
            next();
            break;
        case 27:
            l = calls().slice(mark);
            if (Burn.loading || !l.some(c => c.indexOf("--since") >= 0)) return;
            check(l[0].startsWith("summary --value --json --no-color FORCE=0") && l[0].indexOf("--since") < 0,
                  "summary d'abord, plage ensuite : " + l);
            // Ouvert comme le font les fenêtres (dashboardOpen puis le poke() de leur load()), données et plage périmées.
            Burn.dashboardOpen = false;
            Burn.rangeCache = ({});
            Burn.updatedAt = Date.now() - 120000;   // plus d'1 min : poke() relance le summary
            mark = calls().length;
            Burn.dashboardOpen = true;
            Burn.poke();
            next();
            break;
        case 28:
            if (calls().length === mark || !waited(300)) return;
            check(Burn.loading && JSON.stringify(calls().slice(mark)) === JSON.stringify(["summary --value --json --no-color FORCE=0"]),
                  "ouverture : summary seul, plage différée : " + calls().slice(mark));
            next();
            break;
        case 29:
            l = calls().slice(mark);
            if (Burn.loading || l.length < 2) return;
            eq(JSON.stringify(l), JSON.stringify(["summary --value --json --no-color FORCE=0",
                "summary --value --json --no-color --since " + date(0, "") + " FORCE=0"]), "ouverture : summary, puis la plage à sa fin");
            // Plage en cours puis refresh() (minuteur, Actualiser) : summary différé à la fin de la plage, forcé une fois.
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
                  "refresh pendant la plage : différé : " + l);
            eq(Burn.pendingRefresh, true, "summary en attente de la plage");
            next();
            break;
        case 31:
            l = calls().slice(mark);
            if (Burn.loading || l.length < 2) return;
            eq(l[1], "summary --value --json --no-color FORCE=1", "plage d'abord, summary forcé à sa fin");
            eq(l.filter(c => c.startsWith("summary") && c.indexOf("--since") < 0).length, 1, "un seul summary rejoué");
            check(!Burn.pendingRefresh && !Burn.pendingForce, "attentes consommées");
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
                  "--config sur chaque appel (" + l.length + ") : " + l.filter(c => c.indexOf("--config") < 0));
            eq(read(Burn.cliConfig), "", "config du CLI jamais créée");
            for (var i = 0; i < 25; i++) Burn.note("test", "n" + i);
            eq(Burn.recentErrors.length, 20, "recentErrors : 20 au plus");
            eq(last().msg, "n24", "le plus récent en dernier");
            finish();
            break;
        case 80:   // corrupt : 1er summary du minuteur (rien n'a tourné) en échec, toujours aucun rapport
            if (Burn.loading || Burn.error === "") return;
            check(Date.now() - burnAt >= 2900, "1er refresh à ~3 s (" + (Date.now() - burnAt) + " ms)");
            eq(Burn.summary, null, "aucun summary");
            ps = Burn.providerState("claude");
            eq(ps.state, "unavailable", "claude : rapport en échec");
            eq(ps.label, "Rapport en échec", "label du rapport en échec");
            eq(ps.detail, "agent-burn a échoué (code 3)", "detail = erreur du CLI");
            eq(ps.at, 0, "rapport en échec : aucun relevé");
            refreshWith("empty");   // maison vide
            next();
            break;
        case 81:   // maison vide
            if (!refreshed()) return;
            eq(Burn.dataState, "live", "summary en direct");
            ps = Burn.providerState("claude");
            eq(ps.state, "none", "claude : ni usage, ni abonnement, ni compte");
            eq(ps.at, Burn.updatedAt, "none : instant du summary");
            eq(Burn.providerState("codex").state, "none", "codex absent");
            refreshWith("noauth");
            next();
            break;
        case 82:   // usage Claude sans compte (non connecté ou hors ligne), Codex avec limites
            if (!refreshed()) return;
            ps = Burn.providerState("claude");
            eq(ps.state, "local", "claude : usage local");
            check(ps.detail.indexOf("non connecté") >= 0, "detail : non connecté ou hors ligne — " + ps.detail);
            eq(Burn.providerState("codex").state, "live", "codex en direct");
            refreshWith("installed");
            next();
            break;
        case 83:   // connecté, aucun log : compte sans usage
            if (!refreshed()) return;
            eq(Burn.providerState("claude").state, "live", "claude : compte sans usage → en direct");
            eq(Burn.providerState("codex").state, "none", "codex connu de l'archive seule → non détecté");
            finish();
            break;
        case 90:  // CLI bloqué : summary et relevé léger tués par le watchdog
            if (Burn.error === "") return;
            var dt = Date.now() - burnAt;
            check(Burn.error.indexOf("120 s") >= 0, "erreur de délai : " + Burn.error);
            check(dt >= 123000 && dt <= 133000, "tué vers 3 s + 120 s (" + dt + " ms)");
            check(Burn.summaryCached && Burn.dataState === "cached", "summary en cache gardé");
            eq(Burn.loading, false, "plus de run en cours");
            check(Burn.recentErrors.some(e => e.source === "quota" && e.msg.indexOf("120 s") >= 0), "relevé léger tué à 120 s");
            eq(Burn.account.observedAtMs, seedAt - 7200000, "dernier relevé gardé");
            finish();
            break;
        }
    }
}
