pragma Singleton
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

// Données d'Agent Burn (pill, popover, dashboard) : rapports du CLI agent-burn, limites Claude en
// direct, archive journalière et relevés de quota persistés. Les rapports restent tels que le CLI
// les donne : un montant absent vaut null, jamais 0.
Singleton {
    id: root

    property var summary: null
    property bool summaryCached: false   // relu du disque au démarrage, pas encore remplacé par un run
    property var harnesses: ({})
    property var harnessErrors: ({})   // { agent: message } du dernier harness en échec, effacé à son succès
    property var account: null   // claudeAccount le plus récent, persisté : reste affiché si le CLI échoue
    property bool signInExpired: false   // renouvellement refusé : connexion expirée, ou réseau coupé (jeton expiré)
    // Relevé Claude de plus de 10 min, ou connexion expirée : toujours affiché, mais signalé ancien.
    readonly property bool limitsStale: !!account && (signInExpired || now - (account.observedAtMs ?? 0) > 600000)
    property bool loading: sumProc.running || rangeProc.running || claudeProc.running || codexProc.running
    property string error: ""   // summary et CLI ; les harness ont harnessErrors
    property var recentErrors: []   // 20 derniers échecs { t, source, msg }, le plus récent en dernier, sans stdout
    property real updatedAt: 0
    property bool cliMissing: false
    // Remède affiché quand le CLI manque (BurnPopover) ; l'app de bureau donne le sien.
    property string cliHint: "CLI agent-burn introuvable (~/.local/bin/agent-burn) : relance install.sh"
    property bool dashboardOpen: false
    property string dashboardPage: "all"   // "all" ou un agent
    property bool pendingForce: false   // refresh(true) demandé pendant un run : rejoué à sa fin
    property var pendingHarness: ({})   // loadHarness() pendant le summary : { agent: force }, lancé à sa fin
    property string range: "all"
    property var rangeCache: ({})   // { plage: { at, data } }
    readonly property var rangeSummary: range === "all" ? summary : rangeCache[range]?.data ?? null
    property int refreshInterval: 300000   // tour de fond en ms, réglé par l'app de bureau
    readonly property int cadence: Math.max(60000, refreshInterval)
    // En cache : relu du disque, dernier summary en échec, ou plus vieux que le rythme horaire de la pill.
    readonly property string dataState: !summary ? "unavailable"
        : summaryCached || sumProc.failed || now - updatedAt > 3600000 + cadence ? "cached" : "live"
    // Tokens sans aucun coût : tarifs indisponibles (hors ligne, LiteLLM injoignable), le CLI compte 0 $.
    readonly property bool pricingMissing: (summary?.totals?.totalTokens ?? 0) > 0 && summary.totals.totalCost === 0

    property string bin: Quickshell.env("AGENT_BURN_BIN") || Quickshell.env("HOME") + "/.local/bin/agent-burn"
    // Passée à chaque run, jamais créée : fichier absent = aucune config ; celles de l'utilisateur
    // (./.agent-burn/, ~/.config/agent-burn/, ~/.claude/agent-burn.json : noCost, jq, offline) n'agissent plus.
    readonly property string cliConfig: Quickshell.dataPath("agent-burn-cli.json")
    // Horloge des valeurs dérivées (resets passés, « il y a ») : 10 s, arrêtée pendant l'inactivité.
    property real now: Date.now()

    // Archive journalière : Claude Code supprime ses logs de plus de 30 jours, elle garde tout jour vu.
    property var history: ({})
    readonly property int historyDays: Object.keys(history).length
    property var samples: ({})   // relevés de quota { "<agent>:<key>": [{ t, used }] }, 8 jours
    readonly property string dataDir: Quickshell.dataDir

    // Agents du summary, plus ceux que seule l'archive connaît encore (logs purgés, à 0 $) : la somme
    // des lignes par agent reste égale au total de l'archive.
    readonly property var agents: {
        var cost = {};
        for (var day in history) for (var a in history[day].agents) cost[a] = 0;
        for (var e of summary?.agents ?? []) cost[e.agent] = e.totalCost ?? 0;
        return Object.keys(cost).sort((x, y) => cost[y] - cost[x]);
    }
    // Fenêtre la plus contraignante, tous agents confondus (pill de la barre).
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

    readonly property var spans: ({ today: 0, "7d": 6, "30d": 29 })   // jours avant aujourd'hui
    readonly property var flags: ["--value", "--json", "--no-color"]
    // Agents connus : nom, couleur de marque, harness = page détaillée du CLI (harness claude|codex).
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
    readonly property var knownProviders: ["claude", "codex"]   // toujours listés (réglages, diagnostic), même absents
    readonly property var names: {
        var n = {};
        for (var a in providers) n[a] = providers[a].name;
        return n;
    }

    function agentEntry(agent) { return (summary?.agents ?? []).find(a => a.agent === agent) ?? null; }
    function subEntry(agent) { return (summary?.subscription?.agents ?? []).find(a => a.agent === agent) ?? null; }

    // Claude depuis le compte (relevé direct), les autres agents depuis l'abonnement du summary.
    function windows(agent) {
        var out = [];
        function add(key, label, short, used, resetsAtMs, durationMin, startMs) {
            if (typeof used !== "number") return;
            // Reset passé (relevé ancien) : fenêtre neuve, qui démarrera à la prochaine requête.
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
            add("session", "Session 5 h", "5 h", a.sessionUsedPercent, a.sessionResetsAtMs, 300);
            add("weekly", "Semaine", "sem.", a.weeklyUsedPercent, a.weeklyResetsAtMs, 10080);
            for (var s of a.scoped ?? [])
                add("scoped:" + s.name, s.name + " · semaine", s.name, s.usedPercent, s.resetsAtMs, 10080);
        }
        // Semaine déjà écoulée (logs Codex de plus de 7 j, liveLimits quand même vrai) : relevé expiré, session
        // comprise (sans heure, même âge) → aucune fenêtre plutôt que le vieux % ou un faux 0 %.
        if (e?.window?.elapsedMinutes >= 10080) return out;
        // shortcut: hors Claude, fenêtres supposées de 5 h et 7 j (labels "5h"/"weekly" du CLI) ; lire le label si un agent diffère.
        if (e?.shortWindow) add("session", "Session 5 h", "5 h", e.shortWindow.usedPercent, 0, 300);
        if (e?.window)
            add("weekly", "Semaine", "sem.", e.window.usedPercent, updatedAt + (10080 - e.window.elapsedMinutes) * 60000, 10080);
        return out;
    }

    // Comme l'app Mac : usage du relevé projeté linéairement jusqu'au reset (Forecast), titres de
    // HarnessView ; épuisement avant reset → warn avec le rythme à tenir (verdict Claude).
    function pace(agent, key) {
        var w = windows(agent).find(x => x.key === key);
        var r = { used: w ? w.used : null, elapsed: 0, projected: -1, status: "unknown", title: "Aucune donnée",
                  detail: "Pas encore de relevé pour cette limite.", exhaustAtMs: 0 };
        function set(status, title, detail) {
            r.status = status;
            r.title = title;
            r.detail = detail;
            return r;
        }
        if (!w) return r;
        var dur = w.durationMin * 60000, obs = agent === "claude" ? account.observedAtMs || now : updatedAt;   // instant du relevé
        if (w.resetsAtMs) r.elapsed = Math.max(0, Math.min(1, (obs - w.startMs) / dur));
        if (w.used > 0 && r.elapsed > 0) r.projected = w.used / r.elapsed;
        if (r.projected > 100) r.exhaustAtMs = w.startMs + dur * 100 / r.projected;
        var margin = "De la marge pour continuer";
        if (w.remaining <= 0)
            return set("danger", "Limite atteinte", "Réinitialisation " + (w.resetsAtMs ? until(w.resetsAtMs) : "à une heure inconnue") + ".");
        if (r.exhaustAtMs) {
            var short = dur <= 86400000, left = Math.max(60000, w.resetsAtMs - Math.max(now, obs));
            return set("warn", "Rythme un peu trop rapide", "Épuisement ≈ "
                + new Date(r.exhaustAtMs).toLocaleString(Qt.locale("fr_FR"), short ? "HH:mm" : "ddd HH:mm")
                + ", " + span(w.resetsAtMs - r.exhaustAtMs) + " avant la réinitialisation : reste sous "
                + (w.remaining * (short ? 3600000 : 86400000) / left).toFixed(1) + (short ? " %/h." : " %/jour."));
        }
        if (r.projected > 0) return set("good", margin, "Ton rythme actuel devrait tenir jusqu'à la réinitialisation.");
        if (w.used > 0) return set("unknown", "Rythme inconnu", "Heure de réinitialisation inconnue : pas de prévision.");
        return set("good", margin, "Une prévision apparaîtra dès que ce cycle aura de l'usage.");
    }

    function quotaSamples(agent, key) {
        var w = windows(agent).find(x => x.key === key);
        if (!w) return [];
        var from = w.startMs || now - w.durationMin * 60000;
        return (samples[agent + ":" + key] ?? []).filter(s => s.t >= from);
    }

    // État d'un agent tiré des seuls signaux du CLI, jamais de la présence de fichiers : le CLI ne dit
    // ni « non connecté » ni « hors ligne », et met des 0 pour « inconnu ». at : instant du relevé utilisé.
    // Évaluée dans des bindings à chaque tour d'horloge : lectures seulement.
    function providerState(agent) {
        var claude = agent === "claude", a = claude ? account : null;
        var r = { state: "", label: "", detail: "", error: harnessErrors[agent] ?? "", at: 0 };
        function set(state, label, detail) {
            r.state = state;
            r.label = label;
            r.detail = detail;
            return r;
        }
        if (cliMissing) return set("unavailable", "CLI introuvable", cliHint);
        if (!summary) return set("unknown", "Inconnu", "Pas encore de rapport du CLI agent-burn.");
        r.at = a?.observedAtMs || updatedAt;
        // Aussi pour un jeton expiré sans réseau (sortie de veille) : la cause n'est pas forcément la connexion.
        if (claude && signInExpired)
            return set("expired", "Connexion à vérifier", "Limites refusées : réseau indisponible, ou connexion expirée (claude puis /login).");
        if (!a && !agentEntry(agent) && !subEntry(agent))
            return set("none", "Non détecté", "agent-burn ne trouve ni usage ni abonnement pour cet agent.");
        if (a || windows(agent).length) {
            if (a ? !limitsStale : dataState === "live")
                return set("live", "En direct", claude ? "Limites lues sur le compte Claude, relevé récent."
                    : "Limites du dernier rapport agent-burn (API ou logs de session).");
            return set("stale", "Relevé ancien", claude ? "Dernières limites connues : aucun relevé depuis plus de 10 min."
                : "Dernières limites connues, rapport agent-burn en cache.");
        }
        return set("local", "Usage local", claude ? "Dépense lue dans les logs ; limites indisponibles (non connecté ou hors ligne)."
            : "Dépense lue dans les logs ; limites absentes ou expirées.");
    }
    function stateText(s) { return s === "live" ? "En direct" : s === "cached" ? "En cache" : "Indisponible"; }

    // L'archive l'emporte sur le summary : elle garde le coût d'un jour repassé à 0 hors ligne.
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

    // Les n derniers jours calendaires, aujourd'hui inclus, 0 $ sans usage : un graphe borne son axe
    // au 1er et au dernier point, et une série ne liste que les jours actifs.
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

    // Seul le summary reçoit l'env de forçage ; harness et plage le suivent (sumProc.onExited).
    function refresh(force) {
        if (sumProc.running) {
            pendingForce = pendingForce || !!force;
            return;
        }
        sumProc.forced = !!force;
        launch(sumProc, ["summary"].concat(flags), force ? { AGENT_BURN_FORCE_REFRESH: "1" } : {});
    }
    function poke() { if (Date.now() - updatedAt > 60000) refresh(false); }
    // force : sans attendre 5 min, mais jamais l'env de forçage (relevé partagé du summary relu).
    // Pendant le summary : noté, lancé à sa fin (sumProc.onExited).
    function loadHarness(agent, force) {
        var p = agent === "claude" ? claudeProc : agent === "codex" ? codexProc : null;   // CLI : claude|codex
        if (p && sumProc.running) pendingHarness[agent] = pendingHarness[agent] || !!force;
        else if (p && !p.running && (force || !harnesses[agent] || Date.now() - p.at > 300000))
            launch(p, ["harness", agent].concat(flags));
    }
    // Limites Claude seules (chemin de la barre de menus de l'app Mac) : aucune lecture des logs.
    function loadQuota() {
        if (!quotaProc.running && !sumProc.running)
            launch(quotaProc, ["harness", "claude", "--json", "--no-color"], { AGENT_BURN_QUOTA_ONLY: "1" });
    }
    // Déjà ouvert (autre espace de travail, sous un plein écran) : refermé puis rouvert, Hyprland le
    // remappe au premier plan sur l'espace courant.
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
    // Pendant un summary : rien en parallèle (429 de l'API d'usage), son exited relance la plage (dashboard ouvert).
    function loadRange(force) {
        var c = rangeCache[range];
        if (!spans.hasOwnProperty(range) || rangeProc.running || sumProc.running
            || (!force && c && Date.now() - c.at < 300000)) return;
        var t = new Date();
        rangeProc.key = range;
        launch(rangeProc, ["summary"].concat(flags, ["--since",
            iso(new Date(t.getFullYear(), t.getMonth(), t.getDate() - spans[range])).replace(/-/g, "")]));
    }

    function money(v) { return v == null ? "—" : "$" + Number(v).toLocaleString(Qt.locale("en_US"), "f", 2); }
    // Tokens sans prix (tarifs manquants) : coût inconnu, jamais 0,00 $.
    function priced(cost, tokens) { return tokens > 0 && cost === 0 ? null : cost; }
    function tokens(v) {
        if (v == null) return "—";
        return v >= 1e9 ? (v / 1e9).toFixed(2) + "B" : v >= 1e6 ? (v / 1e6).toFixed(2) + "M"
             : v >= 1e3 ? (v / 1e3).toFixed(1) + "K" : String(v);
    }
    function pct(v, digits) { return v == null ? "—" : Number(v).toFixed(digits ?? 0) + " %"; }
    // Teinte d'un statut de pace().
    function tone(status) {
        return status === "good" ? Colors.good : status === "warn" ? Colors.warn
             : status === "danger" ? Colors.danger : Colors.muted;
    }
    function ago(ms) {
        if (!ms) return "jamais";
        var s = Math.floor((now - ms) / 1000);
        return s < 10 ? "à l'instant" : s < 60 ? "il y a " + s + " s" : s < 3600 ? "il y a " + Math.floor(s / 60) + " min"
             : s < 86400 ? "il y a " + Math.floor(s / 3600) + " h" : "il y a " + Math.floor(s / 86400) + " j";
    }
    function until(ms) { return !ms ? "—" : ms <= now ? "maintenant" : "dans " + span(ms - now); }
    // "4 h 12", "2 j 3 h", "12 min".
    function span(ms) {
        var m = Math.floor(ms / 60000), d = Math.floor(m / 1440), h = Math.floor(m % 1440 / 60);
        if (d > 0) return d + " j" + (h > 0 ? " " + h + " h" : "");
        return h > 0 ? h + " h " + String(m % 60).padStart(2, "0") : Math.max(1, m) + " min";
    }
    function iso(d) { return d.toLocaleString(Qt.locale("C"), "yyyy-MM-dd"); }
    function agentName(a) { return providers.hasOwnProperty(a) ? providers[a].name : a; }
    function agentIcon(a) { return providers.hasOwnProperty(a) ? Qt.resolvedUrl("assets/burn/" + a + ".png") : ""; }
    function agentColor(a) { return providers.hasOwnProperty(a) ? providers[a].color : "#6b7280"; }

    // Variables qui changent la sortie du CLI : retirées (null) sauf si ce run les demande.
    function launch(p, args, env) {
        p.launched = false;
        p.timedOut = false;
        p.exec({ command: [bin].concat(args, ["--config", cliConfig]),
                 environment: Object.assign({ AGENT_BURN_FORCE_REFRESH: null, AGENT_BURN_QUOTA_ONLY: null, LOG_LEVEL: null }, env) });
    }
    function note(source, msg) {
        recentErrors = recentErrors.concat([{ t: Date.now(), source: source, msg: msg }]).slice(-20);
    }
    // Lancement impossible (aucun started) : CLI absent. Le relevé léger reste muet, comme ses autres échecs.
    function missing(p) {
        var msg = "agent-burn introuvable ou non exécutable : " + bin;
        p.failed = true;
        if (p === quotaProc) return note("quota", msg);
        cliMissing = true;
        error = msg;
        note("cli", msg);
    }
    // Rapport summary : avec agents[] (le relevé seul d'AGENT_BURN_QUOTA_ONLY n'en a pas).
    function isReport(d) { return Array.isArray(d.agents); }
    // Fin d'un run → objet JSON (validé par check), ou null et p.problem renseigné (noté dans recentErrors).
    // Erreurs du CLI sur stderr : « Error: CliError("…") » en code 1, option inconnue en code 2.
    function result(p, code, check) {
        cliMissing = false;
        p.failed = true;
        var lines = p.errorOutput.split("\n").map(l => l.trim()).filter(l => l);
        var line = lines.find(l => l.startsWith("Error: ")) ?? lines[0] ?? "";   // un WARN peut précéder l'erreur
        var m = line.match(/^Error: CliError\("(.*)"\)$/);
        var detail = m ? m[1].replace(/\\(["\\])/g, "$1") : line;   // chaîne Debug de Rust : \" et \\ échappés
        if (detail.length > 160) detail = detail.slice(0, 159) + "…";
        if (p.timedOut) p.problem = "agent-burn n'a pas répondu en 120 s : réessaie dans un instant.";
        else if (code === 2) p.problem = "CLI agent-burn incompatible" + (detail ? " : " + detail : "");
        else if (code !== 0) p.problem = "agent-burn a échoué (code " + code + ")" + (detail ? " : " + detail : "");
        else {
            try {
                var d = JSON.parse(p.output);
                if (d && typeof d === "object" && (!check || check(d))) {
                    p.at = Date.now();
                    p.failed = false;
                    return d;
                }
            } catch (e) {}
            p.problem = "Rapport illisible renvoyé par agent-burn.";
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
    // Compte Claude du rapport s'il n'est pas plus ancien que celui gardé.
    function remember(d) {
        var a = d.claudeAccount;
        if (!a || (a.observedAtMs ?? 0) < (account?.observedAtMs ?? 0)) return;
        account = a;
        record("claude", a.observedAtMs ?? now);
    }
    // Un relevé par fenêtre, seulement s'il est plus récent que le dernier (même observedAtMs = doublon).
    // Sur un palier (même % que les deux derniers), le dernier point avance : même tracé, fichier léger.
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
    // Règle de MetricsArchive : un summary complet remplace les jours qu'il contient, les autres restent.
    function merge(d) {
        var h = JSON.parse(JSON.stringify(history));
        for (var a of d.agents) for (var day of a.daily ?? []) {
            if (typeof day.cost !== "number" || !(day.cost >= 0)) continue;
            var e = h[day.date] || (h[day.date] = { cost: 0, tokens: 0, agents: {} }), old = e.agents[a.agent];
            // Coût en baisse sans baisse de tokens, ou 0 $ avec des tokens : tarifs manquants (réseau coupé
            // → prix embarqués, partiels), coût archivé gardé. Limite : une baisse de tarif LiteLLM ne
            // s'applique plus aux jours déjà archivés.
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
    // Fichier persisté → objet ; illisible : contenu brut copié en .bak avant de repartir de zéro.
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

    onDashboardOpenChanged: if (dashboardOpen) loadRange(false)

    FileView { id: historyFile; path: Quickshell.dataPath("burn-history.json"); blockLoading: true }
    FileView { id: quotaFile; path: Quickshell.dataPath("burn-quota.json"); blockLoading: true }
    FileView { id: summaryFile; path: Quickshell.dataPath("burn-summary.json"); blockLoading: true }
    // Un FileView par copie : setText ignore un contenu égal à celui déjà vu par la vue, même d'un autre chemin.
    FileView { id: historyBak; path: historyFile.path + ".bak"; preload: false; blockWrites: true }
    FileView { id: quotaBak; path: quotaFile.path + ".bak"; preload: false; blockWrites: true }
    FileView { id: summaryBak; path: summaryFile.path + ".bak"; preload: false; blockWrites: true }
    Component.onCompleted: {
        history = load(historyFile, historyBak);
        var q = load(quotaFile, quotaBak);
        account = q.account ?? null;
        samples = q.samples ?? {};
        // Dernier summary réussi, affiché « en cache » jusqu'au 1er run : ni fusion ni relevés rejoués.
        var c = load(summaryFile, summaryBak);
        if (c.at > 0 && c.data && isReport(c.data)) {
            summary = c.data;
            updatedAt = c.at;
            summaryCached = true;
        }
    }
    // Au plus une écriture par seconde (modèle NotifCenter), atomique.
    Timer {
        id: saveTimer
        interval: 1000
        onTriggered: {
            historyFile.setText(JSON.stringify(root.history));
            quotaFile.setText(JSON.stringify({ account: root.account, samples: root.samples }));
            if (root.summary) summaryFile.setText(JSON.stringify({ at: root.updatedAt, data: root.summary }));
        }
    }

    // Un run du CLI : un seul à la fois par instance, JSON lu à la fin.
    component Cli: Process {
        property string source   // origine dans recentErrors : summary, range, harness:<agent>, quota
        property real since
        property real at         // fin du dernier run réussi
        property bool failed     // dernier run en échec (lancement, code, délai, JSON)
        property string problem  // message de ce dernier échec
        property bool launched   // started reçu : sinon échec de lancement, sans exited
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
            // Après le summary plutôt qu'en parallèle : son relevé partagé (55 s) sert aux suivants,
            // l'API d'usage répond 429 à plusieurs process à la fois. Harness demandés pendant le run,
            // puis ceux du dashboard ouvert.
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
                root.merge(d);   // jours de la plage plus frais : cartes et tableau des modèles concordent
            } else root.error = rangeProc.problem;
            if (root.range !== key) root.loadRange(false);   // plage changée pendant le run
        }
    }
    // Relevé léger de la pill. Échec muet (recentErrors seulement) : le dernier relevé reste, signalé ancien
    // après 10 min. Le relevé ne porte que semaine et session : limites par modèle et crédits gardent ceux du summary.
    Cli {
        id: quotaProc
        source: "quota"
        onRunningChanged: if (!running && !launched) root.missing(quotaProc)
        onExited: code => {
            var q = root.result(quotaProc, code, x => !!x.window && x.observedAt > 0);
            if (!q) return;
            var w = q.window, s = q.sessionWindow;
            // reset = instant du relevé + part restante de la fenêtre
            var end = x => q.observedAt + (100 - x.elapsedPercent) * x.windowMinutes * 600;
            var a = Object.assign({}, root.account, { observedAtMs: q.observedAt,
                                  weeklyUsedPercent: w.usedPercent, weeklyResetsAtMs: end(w) });
            if (s) Object.assign(a, { sessionUsedPercent: s.usedPercent, sessionResetsAtMs: end(s) });
            root.signInExpired = false;   // relevé direct reçu : la connexion fonctionne
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
    // Timeout 120 s par run, comme l'app Mac : process tué, l'erreur part de son exited.
    Timer {
        interval: 5000; repeat: true; running: root.loading || quotaProc.running
        onTriggered: {
            for (var p of [sumProc, rangeProc, claudeProc, codexProc, quotaProc])
                if (p.running && Date.now() - p.since > 120000) {
                    p.timedOut = true;
                    p.signal(9);
                }
        }
    }

    // 1er refresh 3 s après le chargement, sauf run en cours ou summary réussi depuis moins d'1 min
    // (dashboard ouvert au lancement : déjà lancé par poke()) ; poke() au retour d'inactivité, puis un
    // tour par cadence. Pill sur la session ou la semaine de Claude : relevé léger, summary complet (1 s
    // en ligne, jusqu'à 1 min de CPU hors ligne) au plus toutes les heures pour que l'archive voie chaque
    // jour avant la purge à 30 jours. Sinon (autre agent, limite par modèle) : summary à chaque tour.
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

    IpcHandler {
        target: "burn"
        function refresh(): void { root.refresh(true); }
        function dashboard(): void { root.dashboardOpen = !root.dashboardOpen; }
    }
}
