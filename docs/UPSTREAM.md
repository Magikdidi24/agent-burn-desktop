# Suivre le projet amont

Agent Burn suit [Melvynx/agent-burn](https://github.com/Melvynx/agent-burn) : l'app macOS (modèle des vues) et le
CLI Rust (moteur de données). Le CLI est épinglé dans [`install.sh`](../../../install.sh) par deux lignes qui
changent toujours ensemble :

```sh
AB_REV=<sha complet du commit amont>
AB_VER="agent-burn <version>"      # ce que répond agent-burn --version
```

`install.sh` compile ce CLI pour la barre (`~/.local/bin/agent-burn`) ; `build.ps1` et `linux/build.sh` le
compilent pour l'app de bureau et vérifient que `--version` répond bien `AB_VER`. L'amont ne publie aucun
binaire Linux ni Windows : il faut compiler.

## L'outil `agent-burn-upstream`

Script [`config/quickshell/scripts/agent-burn-upstream.py`](../../../config/quickshell/scripts/agent-burn-upstream.py),
lié en `~/.local/bin/agent-burn-upstream` par `install.sh`. Python 3 et git, rien d'autre (cargo pour `update`).

| Commande | Effet |
|---|---|
| `agent-burn-upstream [status] [--fetch] [--json]` | Rapport (commande par défaut) : commits `AB_REV..main` de l'amont, regroupés, nouveaux tags, fichiers de ce dépôt à revoir. |
| `agent-burn-upstream diff FICHIER` | Diff amont d'un fichier depuis `AB_REV`, par nom (`QuotaChart.swift`) ou chemin depuis la racine de l'amont. |
| `agent-burn-upstream update [REV\|latest]` | Compile le CLI de `REV` (tag ou sha ; `latest` = `main` de l'amont), contrôle son JSON, l'installe et l'épingle. |

- `--fetch` va avec chaque commande : il met d'abord à jour la copie locale de l'amont (réseau). Sans lui, tout
  se lit dans la copie. Hors ligne, `--fetch` prévient (« Attention : hors ligne, rapport depuis le cache ») et
  continue sur la copie.
- La copie est un clone sans blobs ni checkout dans `~/.cache/agent-burn-upstream/repo`. Sans copie, la
  commande demande `agent-burn-upstream status --fetch`.
- Anciennes formes, toujours valides : `--fetch --json` (utilisée par la barre), `--diff FICHIER`,
  `--bump [REV]`.
- Codes de sortie : 0 succès (ou déjà épinglé) ; 1 échec, fichier introuvable ou CLI incompatible (en `--json`,
  le JSON vide porte alors `error`) ; 2 erreur d'usage (commande inconnue, `diff` sans fichier, deux commandes).
- Variables : `AGENT_BURN_UPSTREAM_URL` (dépôt amont), `AGENT_BURN_UPSTREAM_CACHE` (copie et CLI compilé),
  `AGENT_BURN_INSTALL_SH` (`install.sh` à lire et à modifier).
- `--json` : `{ pinned, pinnedVersion, head, headDate, ahead, tags: { cli, mac }, categories: { mac, cli, docs,
  other }, toPort, compareUrl, fetchedAt, error }`.
- Tout texte venu de l'amont (sujets de commits, noms de fichiers, erreurs de git, diff) est débarrassé de ses
  caractères de contrôle (remplacés par `?`) : un sujet de commit ne peut rien faire au terminal. Les tags ne
  sont gardés que s'ils ressemblent à une version (`v1.2.3`, `macos-v…`). `diff` n'a ni couleur ni pager :
  ajouter `| less` pour paginer.

Lecture du rapport texte :

- groupes : App Mac, CLI, Docs, CI/infra, Autres ;
- `[sortie JSON → vérifier Burn.qml]` : le JSON que lit `Burn.qml` change (summary, harness, relevé, compte
  Claude) ;
- `[tarifs]` : les prix changent ;
- sous un commit de l'app Mac, `Fichier.swift → fichiers de ce dépôt` ; « à évaluer » : fichier absent de la
  table `PORT` du script, à y ajouter ; « non porté » : écarté exprès (vue du compte Cursor ; mise à jour
  automatique) ;
- « Fichiers du repo à revoir », puis le lien « Comparer » vers GitHub.

**Dans la barre** ([`BurnUpstream.qml`](../../../config/quickshell/BurnUpstream.qml)) : `--fetch --json` une
fois par jour (premier essai 2 min après le chargement), et à l'ouverture du dashboard si le rapport a plus
d'une heure. Une nouvelle tête amont donne une seule notification et un bandeau dans le dashboard, jusqu'à ce
que × le masque. Boutons du bandeau : « Rapport » (le rapport texte dans kitty) et « GitHub » (comparaison).
L'app de bureau n'a pas ce suivi.

## Synchroniser en 7 étapes

1. **Vérifier l'amont.** Le bandeau de la barre le fait chaque jour. À la main, sans réseau :
   `agent-burn-upstream status` (JSON : `agent-burn-upstream status --json`).

2. **Récupérer.** `agent-burn-upstream status --fetch` met à jour la copie, puis liste les commits
   `AB_REV..main` regroupés, les nouveaux tags, les fichiers de ce dépôt à revoir et le lien de comparaison.
   « À jour : aucun commit amont depuis ta version. » : rien à faire.

3. **Analyser.** Pour chaque fichier amont cité :
   `agent-burn-upstream diff QuotaChart.swift` ou
   `agent-burn-upstream diff rust/crates/agent-burn/src/adapter/all/summary.rs`.
   Avant de porter, vérifier ce qui a déjà divergé ici : `git -C ~/dotfiles status`, puis
   `git -C ~/dotfiles log -p -- <fichier>` pour chaque fichier à revoir (`~/dotfiles` : le clone de ce dépôt).

4. **Intégrer.**
   - Porter dans les fichiers cités : QML partagé (`config/quickshell/Burn*.qml`), app de bureau
     (`desktop/agent-burn/app/…`).
   - Monter le CLI : `agent-burn-upstream update --fetch` (dernier `main`) ou
     `agent-burn-upstream update v20.0.22` (tag ou sha). Voir [ce que garantit `update`](#ce-que-garantit-update).
   - CLI incompatible : rien n'a changé. Adapter le QML en essayant le CLI compilé
     (`AGENT_BURN_BIN=~/.cache/agent-burn-upstream/cli/bin/agent-burn`), puis relancer `update`.
   - [Recapturer les fixtures](#recapturer-les-fixtures) avec le nouveau CLI.
   - Commit : `git -C ~/dotfiles add install.sh` (ou `add -p install.sh` si `update` a signalé des modifications
     locales), plus les fichiers portés, puis
     `git -C ~/dotfiles commit -m "agent-burn : CLI épinglé sur <sha12> (agent-burn <version>)"`.

5. **Vérifier Claude.** Le contrôle hors ligne de `update` ne voit pas `claudeAccount`, `claudeAccountStatus`
   (présent seulement quand la connexion a expiré), le relevé léger (`observedAt`, `window`,
   `sessionWindow`) ni les fenêtres de `harness claude` : ils n'existent qu'en ligne. Recharger la barre, puis
   regarder la pill (reste de la limite la plus serrée), l'onglet Claude de l'aperçu (session, semaine, limites
   par modèle, heure du relevé) et la page Claude du dashboard (économie du forfait, répartition par type de
   jeton, modèles). En ligne, si besoin :

   ```sh
   agent-burn summary --value --json --no-color | jq '{claudeAccount, claudeAccountStatus}'
   AGENT_BURN_QUOTA_ONLY=1 agent-burn harness claude --json --no-color | jq '{observedAt, window, sessionWindow}'
   ```

   Ces runs en ligne peuvent renouveler le jeton et réécrire `~/.claude/.credentials.json` (comportement du
   CLI).

6. **Vérifier Codex.** `update` contrôle déjà `harness codex` et la fenêtre Codex du summary sur une session
   Codex synthétique : attendu « harness codex : ok (10 clés) ». Avec Codex installé :
   `agent-burn harness codex --value --json --no-color | jq '{plan, economics, spendMix, window}'`, puis la
   page Codex du dashboard et ses limites dans l'aperçu. Sans Codex sur la machine, noter « non vérifié sur
   données réelles ».

7. **Vérifier l'app de bureau.** Depuis `desktop/agent-burn/app`, avec le Python du développement : tests
   unitaires, suite du cœur sous le shim (normal, `BURN_TEST=corrupt`, `BURN_TEST=timeout`) et sous qs, selftest
   (OpenGL : session imbriquée ou `xvfb-run`), tests du suivi amont ; commandes dans
   [DEVELOPMENT.md](DEVELOPMENT.md#tests). Puis `git push` : la CI
   ([`agent-burn-desktop.yml`](../../../.github/workflows/agent-burn-desktop.yml)) recompile le CLI épinglé
   (son cache est indexé par `AB_REV`) et reconstruit les paquets.

## Ce que garantit `update`

Dans l'ordre :

1. Résout `REV` dans la copie (`latest`, `main` ou `HEAD` = `origin/main`, jamais la branche locale du clone).
   Même sha qu'`AB_REV` : « install.sh épingle déjà … : rien à faire. », code 0.
2. Lit la version dans `rust/crates/agent-burn/Cargo.toml` de ce commit et refuse ce qui n'est pas une version
   (la ligne `AB_VER="…"` est évaluée par bash).
3. Dit si `install.sh` a des modifications non commitées (« conservées ») ou aucune.
4. Compile à part : `cargo install --locked --force --git <amont> --rev <sha> agent-burn --bin agent-burn
   --root ~/.cache/agent-burn-upstream/cli` (environ 2 min). La barre garde son CLI pendant ce temps.
5. Contrôle le CLI compilé **hors ligne, sur un HOME synthétique** (une session Claude avec forfait Max, une
   session Codex Plus avec limites dans ses journaux), environnement réduit à `HOME` et `PATH`, dossier courant
   = ce HOME : ni les données ni la configuration ni les variables de l'utilisateur ne faussent le résultat.
   - `--version` doit répondre la version attendue ;
   - `summary` : 22 clés lues par `Burn.qml` et les vues ;
   - `harness claude` : 13 clés (les 3 de `window` restent « non vérifiable » hors ligne) ;
   - `harness codex` : 10 clés.

   Une clé absente rend le CLI incompatible ; une clé `null` ou une liste vide est signalée « non vérifiable »
   sans bloquer.
6. Seulement si tout est compatible : copie atomique vers `~/.local/bin/agent-burn` (pas de « Text file busy »
   si la barre lance le CLI au même instant), puis réécriture des seules lignes `AB_REV` et `AB_VER`
   d'`install.sh`, **relu après la compilation** (une modification faite pendant les 2 min reste), avec une copie
   `install.sh.bak` et le diff affiché.

Échec de cargo, version différente ou JSON incompatible : ni `install.sh` ni le CLI installé ne changent. Ces
cas sont couverts par `config/quickshell/scripts/test_agent_burn_upstream.py` (faux dépôt amont, faux cargo).

## Recapturer les fixtures

Les tests et le selftest servent des sorties réelles du CLI, nettoyées, depuis
[`desktop/agent-burn/tests/fixtures/`](../tests/fixtures/). Il n'y a pas de script de recapture : les commandes
sont celles de l'app.

| Fichier | Capture |
|---|---|
| `summary-live.json` | `agent-burn summary --value --json --no-color`, en ligne, compte Claude présent |
| `summary-offline.json` | la même avec `--offline` (tarifs manquants) |
| `harness-claude.json` | `agent-burn harness claude --value --json --no-color` |
| `quota-claude-live.json` | `AGENT_BURN_QUOTA_ONLY=1 agent-burn harness claude --json --no-color` |
| `summary-claude-signin-expired.json` | summary avec `claudeAccountStatus: "signInExpired"` (aussi sans tarifs : coût total 0) |
| `summary-codex-stale-logs.json` | summary sur des journaux Codex de plus de 7 jours |
| `summary-empty-home.json`, `summary-installed-no-usage.json` | summary d'un HOME vide ; d'un compte Claude sans usage |
| `summary-quota-env-leak.json` | summary lancé avec `AGENT_BURN_QUOTA_ONLY=1` hérité (pas d'`agents[]`) |
| `error-claude-config-dir.stderr.txt`, `error-unknown-flag.stderr.txt` | stderr d'un code 1 (`CLAUDE_CONFIG_DIR` invalide) et d'un code 2 (option inconnue) |
| `codex/` | dossier complet pour `AGENT_BURN_FAKE_DIR` : Claude en direct et une session Codex synthétique |

Règles :

- Lancer avec `--config <fichier absent>` comme l'app ; les cas hors ligne dans un HOME factice
  (`env -i HOME=<dossier> PATH=$PATH agent-burn … --offline`).
- Nettoyer : ni nom, ni e-mail, ni identifiant d'organisation ou de compte. Seuls les pourcentages, horodatages,
  montants et noms de modèles restent.
- Caler les dates sur un même jour de capture (dernier jour du rapport) et mettre ce jour dans les deux
  constantes qui décalent les fixtures à aujourd'hui : `fake_cli()` de `app/agentburn/__main__.py` et
  `app/tests/burn-suite/fake/gen.py` (aujourd'hui `date(2026, 10, 23)`).
- Le dossier de premier niveau n'a volontairement pas de `harness-codex.json` : les tests y vérifient l'échec
  du harness Codex. `codex/` en a un.
- Relancer ensuite tests unitaires, suite du cœur (shim et qs) et selftest, avec les deux dossiers de
  fixtures.
