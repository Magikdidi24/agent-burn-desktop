# Architecture d'Agent Burn

Pour qui modifie le code. Utilisation : [README](../README.md) et [USAGE.md](USAGE.md). Signaux et états des fournisseurs :
[PROVIDERS.md](PROVIDERS.md). Tests, build, release : [DEVELOPMENT.md](DEVELOPMENT.md).

## Vue d'ensemble

```
        CLI agent-burn (Rust, projet amont, révision AB_REV de cli.env)
        journaux des agents, tarifs, limites en direct
                     │  JSON sur stdout : summary, harness <agent>, relevé léger
        Burn.qml : cœur partagé (singleton QML, aucune vue)
        runs du CLI, validation, cache, archive journalière, état de chaque fournisseur
                     │  propriétés et fonctions QML
        vues partagées : BurnPopover, BurnDashboardView, BurnQuotaChart, BurnBarChart, BurnButton
                     │
        ┌────────────┴──────────────────────────┐
  Quickshell 0.3.2 (barre, autre dépôt)     app de bureau (PySide6 6.12) + shim.py
  BurnPill, BurnDashboard, BurnUpstream,    Main, PopoverWindow, DashboardWindow, SettingsWindow,
  Colors (palette wallust)                  Colors, tray.py, settings, journaux, diagnostic
```

Trois règles tiennent l'ensemble :

- le CLI calcule (journaux, prix, limites) ; ni le cœur ni l'app ne lisent eux-mêmes les fichiers des agents ;
- `Burn.qml` décide ce qui est affiché et avec quelle fraîcheur, à partir des seuls signaux du CLI ; une valeur
  inconnue reste `null` (affichée « — »), jamais 0 ;
- les vues ne font qu'afficher ; l'hôte (Quickshell ou l'app) fournit fenêtres, icône et plateforme.

## Composants

| Couche | Fichiers | Rôle |
|---|---|---|
| CLI | binaire `agent-burn` de [Melvynx/agent-burn](https://github.com/Melvynx/agent-burn) | Découvre les agents, lit leurs journaux, calcule les prix (LiteLLM, models.dev, sinon prix intégrés), relève les limites (API d'usage Claude, Codex). Compilé par `build.ps1` et `linux/build.sh`, toujours à `AB_REV` ([`cli.env`](../cli.env)). |
| Cœur | [`shared/Burn.qml`](../shared/Burn.qml) | Lance le CLI, valide ses sorties, garde cache, archive et relevés, calcule fenêtres, rythme et état des fournisseurs. |
| Vues partagées | `shared/BurnPopover.qml`, `BurnDashboardView.qml`, `BurnQuotaChart.qml`, `BurnBarChart.qml`, `BurnButton.qml`, `assets/burn/` | Aperçu, dashboard, graphes, bouton accessible au clavier, icônes des agents. Lisent `Burn` et n'agissent que par ses fonctions (`refresh()`, `setRange()`, `openDashboard()`…) et par `Quickshell.execDetached` (ouvrir le dossier des données). |
| Hôte Quickshell (hors de ce dépôt) | `BurnPill.qml`, `BurnDashboard.qml`, `BurnUpstream.qml`, `Colors.qml` de la barre Quickshell de l'auteur, qui garde une copie de `shared/` synchronisée depuis ce dépôt à une révision épinglée | Pill de la barre, fenêtre du dashboard, suivi de l'amont, palette wallust. Propres à Quickshell et Hyprland. |
| Hôte app de bureau | [`app/`](../app/) | Couche de compatibilité (`shim.py`), fenêtres, icône de notification, réglages, journaux, diagnostic, démarrage automatique, selftest. |
| Suivi de l'amont | [`scripts/agent-burn-upstream.py`](../scripts/agent-burn-upstream.py) | Voir [UPSTREAM.md](UPSTREAM.md). |

## Flux de données

1. `Burn` lance le CLI (argv, jamais de shell). Commandes exactes, `--config` toujours en dernier :
   - rapport : `agent-burn summary --value --json --no-color --config <données>/agent-burn-cli.json` ;
   - période du dashboard : la même avec `--since AAAAMMJJ` avant `--config` ;
   - page détaillée : `agent-burn harness claude|codex --value --json --no-color --config …` ;
   - relevé léger des limites Claude : `agent-burn harness claude --json --no-color --config …` avec
     `AGENT_BURN_QUOTA_ONLY=1`.
2. stdout et stderr sont lus à la fin du run. Code 0 et JSON valide : le rapport est accepté s'il a un tableau
   `agents[]` (summary, période), le relevé léger s'il a `window` et `observedAt > 0`. Sinon voir
   [Erreurs](#erreurs).
3. Un summary accepté devient `Burn.summary` (`updatedAt` = maintenant) ; son `claudeAccount` remplace le compte
   gardé s'il n'est pas plus ancien ; `claudeAccountStatus` donne `signInExpired` ; ses jours sont fusionnés
   dans l'archive ; un relevé par fenêtre de limite est ajouté aux échantillons. Une période remplit
   `rangeCache[range]` et fusionne aussi ses jours. Un harness remplit `harnesses[agent]` (ou
   `harnessErrors[agent]`). Un relevé léger met à jour la semaine et la session du compte Claude et remet
   `signInExpired` à faux.
4. Un minuteur écrit au plus une fois par seconde, de façon atomique, `burn-history.json`, `burn-quota.json` et
   `burn-summary.json` dans le dossier de données.
5. Les vues lisent les propriétés de `Burn` et ses fonctions de lecture (`windows()`, `pace()`,
   `providerState()`, `dailySeries()`…). L'horloge `Burn.now` avance toutes les 10 s (arrêtée pendant
   l'inactivité) pour les valeurs qui vieillissent (« il y a 3 min », resets passés).

## Contrat plateforme

`Burn.qml` importe `Quickshell`, `Quickshell.Io` et `Quickshell.Wayland` et n'utilise que 9 symboles. Quickshell
les fournit dans la barre ; [`shim.py`](../app/agentburn/shim.py) les recrée dans l'app avec la même sémantique.

| Symbole | Quickshell | `shim.py` |
|---|---|---|
| `Singleton` | singleton QML | `Scope` (propriété par défaut `children`) |
| `Process` | `command`, `environment` (`null` retire une variable), `running`, `exec()`, `signal()`, `started`, `exited(exitCode, exitStatus)` ; `running: true` écrit avant `command` part après le chargement | sur `QProcess`, mêmes propriétés et signaux, même départ différé de `running` posé avant `command` ; environnement de départ `child_environment()`, dossier courant = dossier de données, chaque run journalisé |
| `StdioCollector` | `text` à la fin du flux | rempli avant `exited`, comme sous qs |
| `FileView` | `path`, `text()`, `setText()`, `preload`, `blockLoading`, `blockWrites`, `printErrors` | lecture synchrone, écriture atomique (`QSaveFile`) ; les réglages de chargement sont acceptés sans effet |
| `IpcHandler` | `target` et fonctions appelables par `qs ipc call` | pas d'IPC ; fonctions appelables depuis Python (tests) |
| `IdleMonitor` | `ext-idle-notify` de Wayland, `timeout`, `isIdle` | Windows : dernière saisie (`GetLastInputInfo`) sondée toutes les 5 s ; ailleurs jamais inactif |
| `Quickshell.env(nom)` | variable ou `null` | `os.environ` ou `null` |
| `Quickshell.dataDir` | dossier de données du shell | dossier passé à `shim.register()` |
| `Quickshell.dataPath(p)` | `dataDir + "/" + p` | idem |

Les vues partagées ajoutent `Quickshell.execDetached` (bouton « Afficher la sauvegarde » : sous Windows,
`QDesktopServices` remplace `xdg-open` ; ailleurs `QProcess` détaché avec l'environnement nettoyé), et
`Quickshell.Widgets` `IconImage` et `ClippingRectangle` (`app/qml/widgets/`). Elles n'importent rien d'autre que
`QtQuick`, `QtQuick.Shapes` et ces modules Quickshell : pas de `QtQuick.Controls`, d'où `BurnButton`
(`Rectangle` et `MouseArea`, focus clavier et nom accessible).

Lecteurs d'écran : `Burn.accessibleText` (faux par défaut) décide si les vues exposent leurs textes. Vrai, chaque
`Txt` de `BurnPopover` et `BurnDashboardView` reçoit, posés en JS, `Accessible.role = StaticText` et un
`Accessible.name` lié à son texte ; `BurnBarChart` et `BurnQuotaChart` reçoivent le rôle `Chart` et une phrase de
résumé (période, total et jour le plus cher ; restant et prévision au reset ; sans graphe, le message affiché).
Faux, aucun objet `Accessible` de plus n'est créé : l'arbre d'accessibilité de la barre reste celui d'avant. L'app de
bureau le met à vrai (`Main.qml`), avec la boucle de rendu basique sous Linux ; la barre le laisse faux, parce que
sous Qt 6.12 ces objets font planter bien plus souvent la boucle de rendu à fil de Wayland, celle qu'elle utilise.
Un `Txt` qui sert de libellé à un `BurnButton` ou à un champ, ou qui a son propre `Accessible.name`, prend
`spoken: false` : sinon il serait annoncé deux fois.

Sémantique reproduite, relevée sous qs : à la fin d'un run, `streamFinished` → `exited` (`running` déjà faux) →
`runningChanged` ; binaire absent : un seul `runningChanged`, sans `started` (c'est ainsi que `Burn` détecte un
CLI introuvable). Raccourcis du shim, commentés dans le code : `exec()` pendant un run ne relance rien à sa fin
(les QML partagés ne le font jamais), tout `signal()` tue le process, les inhibiteurs d'inactivité sont ignorés
sous Windows. En plus de qs : `shim.wait_for_runs(ms)`, appelé par l'app à sa fermeture, attend la fin des runs en
cours (délai commun, `exited` livrés pendant l'attente) et n'en lance plus aucun ensuite, même depuis un
`exited` ; vrai si tous ont fini.

La preuve : [`tests/burn-suite/shell.qml`](../app/tests/burn-suite/shell.qml) teste `Burn.qml` sans fenêtre,
avec un faux CLI, et tourne tel quel sous `qs -p` et sous le shim
([`run_burn_suite.py`](../app/tests/run_burn_suite.py)). Les deux doivent donner le même résultat, dans les
trois modes (normal, fichiers persistés corrompus, CLI bloqué) ; commandes dans
[DEVELOPMENT.md](DEVELOPMENT.md#suite-du-cœur-burnqml).

`shim.register()` ne s'appelle qu'une fois par process : un 2e enregistrement casse l'identité des types côté
PySide, et le singleton `Quickshell` reste lié au premier moteur QML.

## Cœur : API de `Burn`

Publique, utilisée par les vues et les hôtes :

- **Données** : `summary`, `summaryCached`, `harnesses`, `harnessErrors` (`{ agent: message }`), `account`
  (dernier `claudeAccount`), `rangeSummary`, `history`, `historyDays`, `samples`, `recentErrors` (20 derniers
  échecs `{ t, source, msg }`, sans stdout ; `source` parmi `summary`, `range`, `harness:claude`,
  `harness:codex`, `quota`, `cli`).
- **État** : `loading`, `error` (summary, période, CLI absent), `cliMissing`, `signInExpired`, `limitsStale`,
  `dataState` (`live`, `cached`, `unavailable`), `pricingMissing`, `updatedAt`, `now`.
- **Réglé par l'hôte** : `refreshInterval` (ms, 300 000 par défaut ; l'app le lie à ses réglages),
  `cliTimeoutMs` (délai maximal d'un run du CLI, 120 000 ms ; seule la suite de tests le change), `cliHint`
  (remède affiché quand le CLI manque), `bin` (`AGENT_BURN_BIN`, sinon `~/.local/bin/agent-burn`),
  `accessibleText` (faux par défaut ; vrai dans l'app de bureau, faux dans la barre : voir
  [Contrat plateforme](#contrat-plateforme)).
- **Navigation** : `dashboardOpen`, `dashboardPage` (`all` ou un agent), `range` (`all`, `30d`, `7d`, `today`).
- **Registre** : `providers` (`{ id: { name, color, harness } }`), `knownProviders` (`["claude", "codex"]`,
  toujours listés), `names`.
- **Dérivés** : `agents` (agents du summary et de l'archive, par coût décroissant), `tightest`, `remaining`,
  `remainingKey`, `remainingAgent`, `remainingWindow`, `dataDir`, `cliConfig`.
- **Actions** : `refresh(force)`, `poke()` (summary si les données ont plus de 60 s), `loadHarness(agent, force)`,
  `loadQuota()`, `loadRange(force)`, `setRange(r)`, `openDashboard(page)`.
- **Lecture** : `agentEntry(a)`, `subEntry(a)`, `windows(a)`, `pace(a, key)`, `quotaSamples(a, key)`,
  `providerState(a)` (`{ state, label, detail, error, at }`), `stateText(s)`, `dailySeries(a)`,
  `spendSince(a, jours)`, `lastDays(série, n)`, `priced(coût, jetons)` (`null` pour des jetons sans prix).
- **Format** : `money`, `tokens`, `pct`, `tone`, `ago`, `until`, `span`, `iso`, `agentName`, `agentIcon`,
  `agentColor`.
- **IPC** (barre seulement) : `qs ipc call burn refresh`, `qs ipc call burn dashboard`.

Internes, publics par nécessité en QML, à ne pas utiliser ailleurs : `cadence`, `staleAfter`, `pendingForce`,
`pendingRefresh`, `pendingHarness`, `rangeCache`, `spans`, `flags`, `launch`, `note`, `missing`, `isReport`,
`result`, `harnessDone`, `setSummary`, `remember`, `record`, `merge`, `load`, et sur chaque `Cli` : `source`,
`since`, `at`, `failed`, `problem`, `launched`, `timedOut`, `errorOutput`.

`dataState` : `unavailable` sans summary ; `cached` si le summary vient du disque (`summaryCached`), si le
dernier summary a échoué, ou s'il a plus d'une heure plus une `cadence` plus `cliTimeoutMs` (le délai maximal
d'un run : le summary horaire en cours ne fait pas passer en cache) ; sinon `live`. `stateText()` le traduit en « En
direct », « En cache », « Indisponible ». `limitsStale` : relevé Claude plus vieux que `staleAfter` =
max(10 min, 2 × `cadence`), ou connexion à vérifier. `providerState()` est décrit dans
[PROVIDERS.md](PROVIDERS.md#états-dun-fournisseur).

## Erreurs

Messages communs à `error`, `harnessErrors` et `recentErrors.msg` :

| Cas | Message |
|---|---|
| run tué au bout de 120 s | « agent-burn n'a pas répondu en 120 s : réessaie dans un instant. » |
| code 2 (option inconnue du CLI) | « CLI agent-burn incompatible » + « : détail » |
| autre code non nul | « agent-burn a échoué (code N) » + « : détail » |
| code 0 mais JSON invalide, summary sans `agents[]`, relevé léger sans `window` ou sans `observedAt` | « Rapport illisible renvoyé par agent-burn. » |
| lancement impossible | « agent-burn introuvable ou non exécutable : <chemin> » ; pose `cliMissing` et `error` (sauf pour le relevé léger) |

Le détail est la ligne de stderr qui commence par `Error: ` (sinon la première non vide) ; un
`Error: CliError("…")` est déballé et ses échappements Rust (`\"`, `\\`) défaits ; 160 caractères au plus. Un
échec de harness ne touche que `harnessErrors[agent]` (effacé au succès suivant), jamais `error`. Un échec du
relevé léger ne va que dans `recentErrors` : le dernier compte reste, marqué ancien après `staleAfter`. Sans
aucun summary, `error` devient le détail de l'état « Rapport en échec » de chaque fournisseur.

Dans l'app, chaque run est aussi journalisé (logger `agentburn.cli`) : ligne de commande, code, durée, octets, la
ligne d'erreur en cas d'échec ; en DEBUG (« Journal détaillé »), la fin du stderr, 4 000 caractères au plus,
masquée comme le reste du journal.

## Fichiers persistés

Dans le dossier de données (`Quickshell.dataDir` ; pour l'app, voir
[le guide d'utilisation](USAGE.md#où-sont-les-fichiers)) :

| Fichier | Contenu | Règles |
|---|---|---|
| `burn-history.json` | `{ "AAAA-MM-JJ": { cost, tokens, agents: { id: { cost, tokens } } } }` | Un summary remplace les jours qu'il contient, les autres restent. Un coût qui baisse sans baisse de jetons, ou 0 $ avec des jetons (tarifs manquants), garde le coût archivé. |
| `burn-quota.json` | `{ account, samples }` | `samples` : `{ "agent:fenêtre": [{ t, used }] }`, 8 jours, un point par relevé plus récent, paliers compactés. |
| `burn-summary.json` | `{ at, data }` | Dernier summary réussi. Relu au démarrage seulement si `at > 0` et `data.agents` est un tableau : `summaryCached` vrai, ni fusion ni relevé rejoués. |
| `*.bak` | copie brute d'un des fichiers ci-dessus trouvé illisible | Le cœur repart d'un objet vide pour ce fichier. |
| `agent-burn-cli.json` | jamais créé | Passé en `--config` au CLI. |
| `burn-upstream.json` | barre seulement (`BurnUpstream.qml`) | Tête amont notifiée, bandeau masqué, date du dernier rapport. |

Écritures : au plus une par seconde, atomiques (fichier temporaire renommé).

## Rafraîchissement

| Déclencheur | Ce qui part |
|---|---|
| 3 s après le chargement | summary, sauf run en cours ou summary réussi il y a moins de 60 s (dashboard ouvert au lancement) |
| tour de fond, toutes les `cadence` = max(60 s, `refreshInterval`), hors inactivité | relevé léger si la limite la plus serrée est la session ou la semaine de Claude et que le summary a moins d'une heure ; sinon summary |
| retour d'inactivité (`IdleMonitor`, 300 s) | `poke()` |
| aperçu ouvert : à l'ouverture, puis toutes les 60 s | `poke()` |
| dashboard ouvert : à l'ouverture, puis toutes les `refreshInterval` | `poke()`, harness des agents qui ont un abonnement (si le précédent a plus de 5 min), période à l'ouverture et après chaque summary ; à l'ouverture, `Burn` lance lui-même `poke()` avant `loadRange()` : la période attend ce summary, s'il part, et le suit |
| Rafraîchir (boutons, menu, clic du milieu, IPC) | summary forcé (`AGENT_BURN_FORCE_REFRESH=1`), puis harness et période forcés si le dashboard est ouvert |

Un seul run de chaque sorte à la fois (5 instances `Cli` : summary, période, relevé léger, harness claude,
harness codex). Pendant un summary :

- `refresh()` est noté (`pendingForce`) et rejoué, forcé, à sa fin ;
- `loadHarness()` est noté (`pendingHarness`) et lancé juste après lui, même s'il a échoué ;
- `loadRange()` et `loadQuota()` ne partent pas : l'API d'usage répond 429 à plusieurs process à la fois, et le
  relevé que le summary partage (55 s côté CLI) sert aux runs suivants. La fin du summary relance la période
  si le dashboard est ouvert.

Pendant une période, `refresh()` est noté (`pendingRefresh`, et `pendingForce` s'il est forcé) et lancé à sa fin,
forcé si l'un des appels l'était ; c'est alors la fin de ce summary qui recharge la période. Un summary et une
période ne tournent donc jamais ensemble. `loadHarness()` et `loadQuota()`, eux, n'attendent pas la période
(rare : une période dure environ 1 s).

Chien de garde : toutes les 5 s tant qu'un run tourne, un run de plus de `cliTimeoutMs` (120 s) est tué
(`signal(9)`) ; son `exited` produit le message de délai dépassé.

## Isolation du CLI

Le JSON doit dépendre des seules données des agents, pas de la configuration de la machine :

- `--config <données>/agent-burn-cli.json` en fin de chaque commande. Avec `--config`, le CLI ne lit que ce
  fichier, et un fichier absent vaut « aucune configuration » : `./.agent-burn/`,
  `~/.config/agent-burn/agent-burn.json` et `~/.claude/agent-burn.json` (`noCost`, `jq`, `offline`, qui
  changent le JSON) sont ignorés. Vérifié avec le CLI 20.0.21 dans des HOME factices, hors ligne.
- `AGENT_BURN_FORCE_REFRESH`, `AGENT_BURN_QUOTA_ONLY` et `LOG_LEVEL` sont retirés (`null`) sauf quand le run les
  pose lui-même (summary forcé, relevé léger). Un `AGENT_BURN_QUOTA_ONLY` hérité changerait la forme du summary.
- Dans l'app, en plus, `shim.child_environment()` :
  - app gelée : retire `_PYI_*`, `QT_PLUGIN_PATH`, `QML2_IMPORT_PATH`, `QML_IMPORT_PATH`, et rend à
    `LD_LIBRARY_PATH` sa valeur d'avant le lanceur PyInstaller (`LD_LIBRARY_PATH_ORIG`) ou le retire : un
    programme Qt du système lancé par `xdg-open` chargerait sinon le Qt du bundle ;
  - Windows : `HOME` = `USERPROFILE` (le CLI lit `HOME` avant `USERPROFILE`) ;
  - garde le reste (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`…) ;
  - dossier courant = dossier de données.
- Sous Quickshell, le dossier courant est celui de qs ; `--config` suffit à neutraliser `./.agent-burn/`.

## App de bureau

### Démarrage (`agentburn/__main__.py`)

1. Faux CLI : avec `AGENT_BURN_FAKE_DIR` et un argv `summary`, `harness claude|codex` ou `--version`, l'exe sert
   les fixtures de ce dossier (dates décalées à aujourd'hui) et sort, sans charger Qt. Sert aux tests et au
   selftest de l'app gelée, où `AGENT_BURN_BIN` est l'exe lui-même. Hors selftest, la variable est signalée
   dans le journal.
2. Options : `--selftest DIR`, `--show popover|dashboard` (dev : cette fenêtre seule, sans icône).
3. Sous Linux, `QSG_RENDER_LOOP=basic` (retirée des process lancés : `shim.APP_VARS`) sauf valeur déjà définie
   ou plateforme `offscreen` (selftest) : la boucle
   de rendu à fil de Qt 6.12 plante dans QtWaylandClient (`QWaylandWindow::beginFrame`) pendant l'affichage d'une
   fenêtre, bien plus souvent avec les textes exposés aux lecteurs d'écran (vu en session KWin imbriquée, Mesa
   llvmpipe : aucun plantage en 9 essais avec la boucle basique). Hors écran, rien de Wayland, et la boucle
   basique capturerait mal le haut de l'aperçu agrandi.
4. `AGENT_BURN_BIN` par défaut : `<dossier de l'exe>/bin/agent-burn(.exe)` une fois gelé (exe aux liens
   résolus : `/opt/agent-burn-desktop/` même lancé par `/usr/bin/agent-burn-desktop`), sinon `agent-burn` du
   `PATH`, sinon `~/.local/bin/agent-burn`.
5. Journal ([`logs.setup`](../app/agentburn/logs.py)) avant tout le reste.
6. `setDesktopFileName("io.github.magikdidi24.AgentBurn")` (app_id Wayland, portails) ; sous Linux,
   `-platformtheme xdgdesktopportal` sauf si `QT_QPA_PLATFORMTHEME` est défini (et jamais en selftest).
7. Mode icône : instance unique. D'abord un `QLockFile` (`<socket>.lock`, sous Windows
   `<cache>\AgentBurn-<utilisateur>-<session>.lock`), périmé seulement si son process est mort : deux lancements
   simultanés sondaient chacun avant le `listen()` de l'autre, et `listen()` n'est pas exclusif sous Windows (deux
   serveurs sur un même tube). Le perdant réessaie de joindre le gagnant pendant 3 s environ, puis sort en 0 ; un
   verrou impossible à créer (dossier en lecture seule) laisse démarrer comme avant. Le gagnant sonde l'instance
   existante (`QLocalSocket`) : si elle répond, elle ouvre son dashboard et ce process sort en 0. Sinon
   `QLocalServer` avec `UserAccessOption` ; un `listen()` en échec est journalisé.
8. Polices du bundle, icône de fenêtre, `Settings` (en mémoire pour le selftest) et `Desktop`, schéma de
   couleurs.
9. `runtime.assemble()` prépare le dossier QML, `register()` enregistre le shim puis les singletons `Settings`
   et `Desktop` (`import AgentBurn`, QML de l'app seulement), puis `Main.qml` est chargé.
10. `fit()` : dashboard (1200 × 800) et Paramètres (620 × 680) centrés sur l'écran principal, réduits sur un
    petit écran (48 px de marge) sans passer sous leur taille minimale ; écran plus petit que ce minimum : le
    minimum est ramené à l'écran, la fenêtre y tient entière et son contenu défile.
11. Selftest, ou : barres de titre sombres (Windows), icône de notification, règles de fermeture
    (`quit_when_closed()` : dashboard fermé avec `closeToTray` faux, l'app quitte une fois Paramètres fermé aussi,
    sauf si le dashboard est rouvert entre-temps ; sans zone de notification, à la fermeture de la dernière
    fenêtre), connexion des lancements suivants au dashboard, boucle Qt.
12. À la sortie de la boucle : `shim.wait_for_runs(5000)`, puis destruction du moteur QML.

### Modules Python (`app/agentburn/`)

| Module | Rôle |
|---|---|
| `shim.py` | Types Quickshell (voir plus haut), `child_environment()`, journal `agentburn.cli` de chaque run (ligne de commande, code, durée, octets ; fin du stderr en DEBUG ; jamais stdout), `wait_for_runs()` à la fermeture. |
| `runtime.py` | Assemble les QML partagés (`SHARED`, aussi lu par `agentburn.spec`), `assets/burn/`, les QML de l'app et un `qmldir` (singletons `Burn` et `Colors`) dans `<cache>/qml-<sha1 du contenu>`. Réutilisé seulement s'il est identique octet pour octet, sans fichier en plus ; sinon reconstruit, puis renommé de façon atomique. |
| `paths.py` | Seul endroit qui connaît les dossiers par OS et le nom d'instance unique. |
| `settings.py` | Singleton `Settings` : JSON validé (BOM UTF-8 accepté), écrit de façon atomique, `.bak` d'un fichier illisible (JSON invalide, imbrication extrême), `reset()`. Le démarrage automatique est délégué au module de la plateforme (absent en dev). |
| `logs.py` | Fichier tournant (1 Mo × 3, UTF-8), stderr hors app gelée (remis en UTF-8, même redirigé sous Windows), masquage des secrets sur chaque handler, messages Qt sur le logger `qt`, exceptions non rattrapées journalisées (fil principal, threads), niveau DEBUG à chaud. Les lignes DEBUG : fin du stderr du CLI (`shim.py`), réglages en vigueur et chaque écriture, thème du système, clics sur l'icône, 2es lancements. |
| `diagnostics.py` | Singleton `Desktop` : versions (app, `build-info.json` ou `cli.env` en dev, `agent-burn --version` lu en tâche de fond : « illisible » si vide, « sans réponse (10 s) » s'il bloque), plateforme, écrans, dossiers, ouverture des dossiers, texte de diagnostic masqué. |
| `tray.py` | `QSystemTrayIcon` et son menu, icône dessinée par taille, placement de l'aperçu (`place()`, X11 et Windows ; sous Wayland, hauteur bornée par l'écran où le compositeur l'a mis), revérification de la zone de notification toutes les 5 s pendant toute la session : hôte apparu (icône recréée sous xcb), disparu ou revenu, `Desktop.trayAvailable` suivi dans les deux sens et journalisé. |
| `platform_win.py` | `ctypes` et `winreg` : inactivité, barre de titre sombre (DWM), clé `Run` et `StartupApproved\Run`, `AllowSetForegroundWindow`, numéro de session. |
| `platform_linux.py` | Fichier autostart XDG de l'utilisateur, clé `Exec` échappée selon la spec Desktop Entry ; `$APPIMAGE` pour une AppImage ; `Hidden=true` ou `X-GNOME-Autostart-enabled=false` valent désactivé ; `OSError` (rien d'écrit) pour un chemin d'exe avec un caractère de contrôle, `%` ou `\`. |
| `selftest.py` | Rendu de l'icône, de l'aperçu, du dashboard et des 4 sections des réglages ; refuse une capture vide, d'une seule couleur, de mauvaise taille ou au coin transparent ; écrit `selftest.json`. |

### QML de l'app (`app/qml/`)

- `Main.qml` : racine (`QtObject`), lue par `tray.py` et `selftest.py` : `remaining`, `tone`, `tooltip`,
  `menuLines`, `popover`, `dashboard`, `settingsWindow` ; `openDashboard()`, `refresh()`,
  `openSettings(section)`. Lie `Burn.refreshInterval` à `Settings.refreshMinutes` et `Burn.accessibleText` à
  vrai, pose `Burn.cliHint` et `Colors.theme`. Sans limite et avec `Burn.error`, l'infobulle (et sans données,
  la ligne de menu) se termine par « échec du CLI (voir Paramètres › Diagnostic) ».
- `PopoverWindow.qml` : fenêtre sans bordure autour de `BurnPopover`, défilante si l'écran est trop bas : défile
  jusqu'au contrôle atteint par Tab, Page précédente / Page suivante / Début / Fin.
- `DashboardWindow.qml` : fenêtre autour de `BurnDashboardView` (bouton Paramètres activé), recharge au rythme
  des réglages. Le défilement au clavier (focus suivi, Page précédente / Page suivante / Début / Fin) et Échap
  dans le filtre des modèles sont dans `BurnDashboardView`, partagé avec la barre.
- `SettingsWindow.qml` : contrôles Qt Quick (Fusion) aux couleurs de `Colors` ; sections Général, Fournisseurs,
  Diagnostic, À propos. Entrée comme Espace (`activate()`), flèches gauche et droite entre les options d'une
  rangée (`Choice`), onglet courant en gras et souligné et anneau de focus (`Tab`, `Ring`), `open(section)` qui
  donne le focus à l'onglet de la section, réinitialisation en deux temps (5 s), champs de chemin coupés
  n'importe où.
- `Colors.qml` : même API que le `Colors.qml` de la barre ; thème choisi ou clair/sombre du système (inconnu :
  sombre) ; accent du système rendu lisible (contraste 4,5:1) ; texte secondaire (`muted`) à 4,5:1 au moins sur
  le fond et les cartes, en clair comme en sombre.
- `widgets/` : `IconImage` et `ClippingRectangle` de `Quickshell.Widgets`.

### Processus et fils d'exécution

- Un process, un fil principal Qt ; tout est piloté par des événements. L'app ne crée aucun thread Python.
- Process enfants : les runs du CLI (`QProcess` asynchrone, sorties lues à la fin), `agent-burn --version`
  (tué après 10 s), `xdg-open` détaché, et en test ou selftest l'exe lui-même en faux CLI.
- Lectures et écritures de fichiers synchrones sur le fil principal (petits JSON).
- Instance unique par `QLocalServer` : socket `$XDG_RUNTIME_DIR/AgentBurn.sock`, ou tube
  `AgentBurn-<utilisateur>-<session>` sous Windows ; précédé du verrou `QLockFile` (voir
  [Démarrage](#démarrage-agentburn__main__py)).
- À la sortie, `shim.wait_for_runs(5000)` attend la fin des runs du CLI en cours (5 s au plus, sans en lancer
  d'autre) : tué, un run pourrait perdre le jeton Claude qu'il vient de renouveler. Puis le moteur QML est
  détruit avant les objets Python du shim ; un run encore en cours à ce moment est tué. Un run fini pendant
  l'attente met `Burn` à jour, mais l'écriture différée d'une seconde peut ne pas partir : le summary suivant
  refusionne ces jours.

## Sécurité

- Process lancés en argv, jamais par un shell. Textes venus du CLI affichés en `Text.PlainText`.
- Aucun appel réseau de l'app. Le CLI, lui, télécharge les tarifs, interroge les API d'usage et réécrit
  `~/.claude/.credentials.json` quand il renouvelle le jeton Claude.
- Écritures atomiques (`QSaveFile`, `os.replace`) ; fichiers illisibles copiés en `.bak`, jamais écrasés.
- Isolation du CLI (configuration, environnement, dossier courant) et environnement de l'app gelée nettoyé
  pour tout enfant.
- Instance unique : socket dans le dossier d'exécution de l'utilisateur (0700) ou tube nommé avec utilisateur
  et session, accès réservé à l'utilisateur (`UserAccessOption`) ; verrou pris avant de sonder, pour que deux
  lancements simultanés ne fassent pas deux instances (deux icônes, CLI en double, réglages écrasés).
- Démarrage automatique sous Linux : chemin d'exe refusé s'il contient un caractère de contrôle (un saut de ligne
  ajouterait un `Exec` choisi par le nom d'un dossier), `%` ou `\` (entrée refusée par GLib ou systemd).
- Copie des QML relue octet pour octet à chaque lancement : un fichier modifié dans le cache n'est pas exécuté.
- Journal et diagnostic masquent les secrets (motifs : voir le
  [guide d'utilisation](USAGE.md#vie-privée--ce-que-lapp-lit-et-écrit)) ; le diagnostic ne contient ni variable
  d'environnement ni contenu de fichier.
- `AGENT_BURN_FAKE_DIR` reste actif dans l'app livrée (le selftest gelé en a besoin) : signalé dans le journal
  hors selftest ; seuls `harness claude|codex` sont servis, jamais un chemin tiré d'argv.
- Builds : police Nerd Font et outils téléchargés (nfpm, appimagetool, runtime
  AppImage, rustup-init) vérifiés par sha256 ; dépendances Python installées depuis un verrou haché
  (`app/requirements.lock`, `--require-hashes`) ; image de build Linux épinglée par empreinte. CI : actions
  épinglées par SHA, `persist-credentials: false`, `contents: read` partout sauf le job de release.
- Installeur Windows : ses lignes `[InstallDelete]` ne vident les sous-dossiers du bundle que par-dessus une
  installation d'Agent Burn (`OwnInstall` : `AgentBurn.exe` et `unins000.dat` présents), et l'installeur ne
  propose pas de choisir le dossier (`DisableDirPage`) : sinon un dossier existant pris à la main serait vidé à la
  mise à jour suivante. Seul `/DIR=` en ligne de commande peut encore viser un autre dossier.
- Points connus : `AllowSetForegroundWindow(ASFW_ANY)` au 2e lancement sous Windows (tout process peut prendre
  le premier plan jusqu'à la saisie suivante) ; en dev sous Windows, `shutil.which("agent-burn")` cherche aussi
  dans le dossier courant ; la désinstallation Windows arrête tout `AgentBurn.exe` de l'utilisateur par son nom.

## Ajouter un fournisseur

Le CLI fait la découverte : un agent qu'il connaît apparaît déjà, avec son identifiant pour nom et une couleur
grise. Pour l'intégrer proprement :

1. **Registre** : ajouter `<id>: { name, color, harness: false }` à `providers` dans `Burn.qml`, et l'icône
   `shared/assets/burn/<id>.png` (copiée par `runtime.assemble()` et par `agentburn.spec`).
   `harness` n'est qu'indicatif : aucun code ne le lit.
2. **Toujours listé** (réglages, diagnostic, menu de l'icône, carte Fournisseurs) même absent : l'ajouter à
   `knownProviders`. Sinon il n'est listé que vu dans un rapport.
3. **Limites** : rien à faire si le CLI le met dans `subscription.agents` avec `window` / `shortWindow` ;
   `windows()` les affiche, avec l'hypothèse 5 h / 7 jours et l'expiration à 7 jours. Si ses fenêtres diffèrent,
   lire leur durée dans le rapport (voir le commentaire `shortcut` de `windows()`).
4. **Page détaillée** (`harness <id>`) : seuls `claude` et `codex` ont un `Cli` dans `Burn.qml`. Il faut un
   nouveau `Cli` (`source: "harness:<id>"`), son cas dans `loadHarness()`, la liste rejouée à la fin du summary
   (`["claude", "codex"]`), le libellé de la source dans `SettingsWindow.qml`, les clés lues dans `KEYS` de
   `agent-burn-upstream.py`, et le faux CLI (`fake_cli` de `__main__.py`, qui n'accepte que `claude` et `codex`).
5. **État** : `providerState()` s'applique tel quel ; ses branches propres à Claude ne concernent que `claude`.
6. **Tests** : une fixture réelle nettoyée dans `tests/fixtures/` (dates calées sur le jour de
   capture, voir [UPSTREAM.md](UPSTREAM.md#recapturer-les-fixtures)), son cas dans `burn-suite/fake/gen.py` et
   `shell.qml`, la suite sous qs **et** sous le shim, le selftest pour le rendu.
7. **Suivi de l'amont** : faire correspondre les nouveaux fichiers de l'app Mac dans la table `PORT`.
