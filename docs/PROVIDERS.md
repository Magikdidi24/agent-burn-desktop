# Fournisseurs : ce qui est lu, et d'où

Le CLI `agent-burn` fait toute la lecture ; `Burn.qml` en déduit l'état de chaque agent
([`providerState()`](../shared/Burn.qml)). Les faits sur le CLI ci-dessous viennent de son
code à la révision épinglée (20.0.21, `9ce6d8e`) et de 73 runs réels faits pendant l'audit.

Deux principes :

- **Seulement les signaux du CLI**, jamais la présence de fichiers : l'app ne regarde pas si `~/.claude` ou
  `~/.codex` existent. Le CLI ne dit ni « non connecté » ni « hors ligne », et écrit `0` là où il veut dire
  « inconnu » : l'état se déduit de ce qu'il renvoie, et ce qui manque reste affiché comme manquant.
- **Rien d'inventé** : un montant absent vaut `null` (« — »), une limite expirée n'est pas affichée, un relevé
  ancien est marqué comme tel.

## Claude Code

**Ce que le CLI lit** (sous Windows, tout est sous `%USERPROFILE%`, l'app posant `HOME=%USERPROFILE%`) :

| Quoi | Où | Pour |
|---|---|---|
| Journaux de session | `projects/` de `~/.claude` et de `$XDG_CONFIG_HOME/claude`, ou des dossiers de `CLAUDE_CONFIG_DIR` (liste séparée par des virgules ; chacun doit contenir `projects/`, sinon tout le rapport échoue) | dépense, jetons, modèles, jours |
| Forfait | `~/.claude.json` (`oauthAccount`), d'abord celui de `CLAUDE_CONFIG_DIR` | nom et prix du forfait |
| Jeton de connexion | `~/.claude/.credentials.json`, toujours sous `HOME`, même avec `CLAUDE_CONFIG_DIR` | limites en direct |
| Limites mises en cache par Claude Code | `~/.claude.json` (`cachedUsageUtilization`) | limites sans appel réseau |

Lignes illisibles ou fichiers sans droit de lecture : ignorés sans message (code 0).

**Limites en direct.** Le CLI interroge `api.anthropic.com/api/oauth/usage` (5 s de délai). Il partage son
dernier relevé pendant 55 s entre tous ses process (cache `~/.cache/agent-burn/claude-usage.json`), et attend de
1 à 15 min après un 429. Un jeton expiré est renouvelé auprès de `platform.claude.com` (15 s), et le nouveau
jeton **réécrit `~/.claude/.credentials.json`**.

Ce que `Burn` en tire :

- **Compte** : `claudeAccount` du summary (avec `--value`, en ligne seulement) : session de 5 h, semaine,
  limites par modèle (`scoped`), crédits supplémentaires, instant du relevé (`observedAtMs`). Gardé dans
  `burn-quota.json` et affiché tant qu'aucun relevé plus récent n'arrive, même si le CLI échoue.
- **Relevé léger** : `AGENT_BURN_QUOTA_ONLY=1 agent-burn harness claude --json --no-color` renvoie la semaine et
  la session (`observedAt`, `window`, `sessionWindow`), en 0,3 s, sans lire les journaux. C'est le tour de fond
  quand la limite la plus serrée est une fenêtre Claude. Les limites par modèle et les crédits gardent les
  valeurs du dernier summary. Un échec (code 1 « Live quota unavailable » hors ligne) est muet : seulement
  dans les dernières erreurs.
- **Page détaillée** : `harness claude` donne l'économie du forfait (`economics`) et la répartition par type de
  jeton (`spendMix`) de la page Claude du dashboard.
- **Fraîcheur** : `limitsStale` dès que le relevé est plus vieux que `staleAfter` = max(10 min, 2 × `cadence`),
  soit deux tours de fond (un relevé manqué) : 10 min aux rythmes de 1 et 5 min, 30 min à 15 min, 60 min à
  30 min ; ou dès que la connexion est à vérifier.
- **Reset passé** : une fenêtre dont la réinitialisation est passée repart à 0 %, sans attendre de relevé.

**Signal de connexion.** Le seul est `claudeAccountStatus: "signInExpired"` dans le summary. Le CLI le produit
quand le renouvellement du jeton est refusé… mais aussi quand le jeton a expiré et que le réseau manque (sortie
de veille avant le Wi-Fi). Après un refus, il bloque les essais 10 min (`AGENT_BURN_FORCE_REFRESH=1`, posé par
« Rafraîchir », passe outre). D'où le libellé « Connexion à vérifier », qui cite les deux causes, et jamais
« Connecte-toi ». Le statut disparaît au summary suivant sans lui, ou dès qu'un relevé léger réussit.
Sans jeton du tout, ou hors ligne avec un jeton valide, le CLI ne renvoie ni compte ni statut : c'est
« Usage local », ou « Relevé ancien » si un compte relevé plus tôt est encore gardé.

**Tarifs.** En ligne, prix de LiteLLM (raw.githubusercontent.com), sinon models.dev, 10 s chacun. Hors ligne ou
injoignables : prix intégrés au CLI, qui ne connaissent pas les modèles Claude récents (`claude-*-5-5`,
`opus-5` à la révision épinglée) et les comptent à **0 $**, sans le dire, avec beaucoup plus de calcul (65 s de
CPU au lieu de 2 sur un vrai historique pendant l'audit). Côté app :

- `pricingMissing` : jetons > 0 et coût total 0 → bandeau « Tarifs indisponibles : montants incomplets (réseau
  coupé ou tarifs non téléchargés) » ;
- `priced(coût, jetons)` : des jetons à 0 $ s'affichent « — », jamais « $0.00 » (totaux, jours, agents,
  modèles, graphes) ;
- l'archive garde le coût déjà connu d'un jour qui repasse à 0 $ avec des jetons.

## Codex

**Ce que le CLI lit** : `$CODEX_HOME` (liste séparée par des virgules) ou `~/.codex` : `sessions/` et
`archived_sessions/` pour la dépense et les jetons.

**Limites.** En ligne avec `~/.codex/auth.json`, le CLI interroge `chatgpt.com/backend-api/wham/usage`. Sinon il
prend les `rate_limits` les plus récents de ses journaux (24 derniers fichiers), **sans regarder leur âge**, et
annonce quand même `liveLimits: true`. Le summary les donne dans `subscription.agents[]` : forfait, prix,
`window` (semaine : `usedPercent`, `elapsedMinutes`) et `shortWindow` (session : `usedPercent` seul).

Ce que `Burn` en tire :

- **Semaine** : réinitialisation calculée = instant du rapport + (7 jours − `elapsedMinutes`).
- **Session** : supposée de 5 h, sans heure de réinitialisation (le CLI n'en donne pas) : pas de prévision,
  « Rythme inconnu » dès qu'elle a de l'usage.
- **Expiration** : si `window.elapsedMinutes` ≥ 7 jours (journaux de plus d'une semaine), aucune fenêtre n'est
  affichée, session comprise : ni le vieux %, ni un faux 0 %. L'agent passe en « Usage local » et ne compte
  plus pour l'icône.
- **Page détaillée** : `harness codex` (économie du forfait, répartition) pour la page Codex du dashboard.
- **Connexion** : aucun signal. Le CLI traite tout refus de l'API comme une absence de réponse : Codex n'est
  jamais « Connexion à vérifier ».

Codex n'a été vu qu'à travers des fixtures (session synthétique : forfait Plus, semaine 34 %, session 12 % ;
journaux de 9 jours pour l'expiration), jamais avec un vrai compte.

## Autres agents

Registre de `Burn.qml` : Cursor, OpenCode, Gemini, Pi, Droid, OpenClaw, Kimi, Amp, Qwen (nom, couleur, icône).
Un agent que le CLI renvoie sans être au registre s'affiche avec son identifiant et une teinte grise.

- **Usage seulement** : dépense, jetons, modèles et jours, tels que `agents[]` les donne.
- **Pas de page détaillée** : le CLI n'a de `harness` que pour `claude` et `codex`.
- **Limites** : seulement si le CLI les met dans `subscription.agents[]`, avec la même lecture que Codex
  (fenêtres supposées de 5 h et 7 jours, expiration à 7 jours). Les crédits Cursor (`cursorAccount`) ne sont
  pas lus.

## États d'un fournisseur

`Burn.providerState(agent)` renvoie `{ state, label, detail, error, at }`. Règles dans cet ordre, la première
qui s'applique gagne :

| # | `state` | Signal du CLI | Libellé | Détail affiché |
|---|---|---|---|---|
| 1 | `unavailable` | le binaire ne se lance pas (summary, période ou harness) | CLI introuvable | `Burn.cliHint` (barre : « CLI agent-burn introuvable (~/.local/bin/agent-burn) : relance install.sh » ; app : « Agent Burn ne trouve pas son CLI (<chemin>) : réinstalle l'application. ») |
| 2 | `unavailable` | aucun summary, ni réussi ni en cache, et `Burn.error` posé (summary ou période en échec) | Rapport en échec | `Burn.error`, le message du CLI (voir [ARCHITECTURE.md](ARCHITECTURE.md#erreurs)) |
| 3 | `unknown` | aucun summary, ni réussi ni en cache, et pas d'erreur | Inconnu | Pas encore de rapport du CLI agent-burn. |
| 4 | `expired` | Claude : `claudeAccountStatus: "signInExpired"` | Connexion à vérifier | Limites refusées : réseau indisponible, ou connexion expirée (claude puis /login). |
| 5 | `none` | ni `claudeAccount` (Claude), ni ligne dans `agents[]`, ni dans `subscription.agents[]` | Non détecté | agent-burn ne trouve ni usage ni abonnement pour cet agent. |
| 6 | `live` | limites présentes et fraîches : Claude, relevé de moins de `staleAfter` ; autres, fenêtre non expirée et rapport « En direct » | En direct | Claude : Limites lues sur le compte Claude, relevé récent. Autres : Limites du dernier rapport agent-burn (API ou logs de session). |
| 6 | `stale` | limites présentes mais anciennes : Claude, relevé plus vieux que `staleAfter` ; autres, rapport « En cache » | Relevé ancien | Claude : Dernières limites connues : aucun relevé depuis plus de N min (N = `staleAfter`, 10 au moins). Autres : Dernières limites connues, rapport agent-burn en cache. |
| 7 | `local` | usage sans limite : Claude sans compte ; autres sans fenêtre, ou fenêtre expirée | Usage local | Claude : Dépense lue dans les logs ; limites indisponibles (non connecté ou hors ligne). Autres : Dépense lue dans les logs ; limites absentes ou expirées. |

- `error` : dernière erreur du harness de cet agent (`harnessErrors[agent]`), affichée sur sa seule page.
- `at` : instant du relevé utilisé (`observedAtMs` de Claude, sinon l'heure du rapport) ; 0 pour `unavailable`
  et `unknown`.
- Le rapport en échec reprend `state: "unavailable"` du CLI introuvable : aperçu, dashboard et Paramètres lui
  donnent la même teinte d'alerte.
- Un agent connu de la seule archive locale (journaux purgés) est `none`, mais garde ses jours dans
  l'historique.
- La fonction ne fait que lire : elle est évaluée dans les liaisons QML à chaque tour d'horloge.

Les mêmes libellés reviennent partout : badge de l'onglet et de la page, carte Fournisseurs, Paramètres →
Fournisseurs, menu de l'icône (sans limite), texte de diagnostic.

## Ce qui n'est pas disponible, et n'est jamais inventé

| Information | Pourquoi | Affiché à la place |
|---|---|---|
| Raison de l'absence des limites Claude (non connecté, hors ligne, 429) | aucun statut du CLI | « Usage local » avec les deux causes possibles |
| Connexion Codex expirée | aucun signal du CLI | rien : Codex reste « Usage local » ou « En direct » selon ses fenêtres |
| Heure de réinitialisation de la session Codex | absente du rapport | fenêtre sans heure, « Rythme inconnu » |
| Limites Codex de plus de 7 jours | le CLI les donne comme actuelles | aucune fenêtre |
| Prix d'un modèle inconnu du CLI | compté 0 $ par le CLI | « — » et bandeau des tarifs |
| Durée réelle des fenêtres hors Claude | libellés du CLI non lus | hypothèse 5 h / 7 jours (raccourci documenté dans `windows()`) |
| Crédits Cursor, pages Cursor de l'app Mac | non portés | rien |
| Présence d'un agent sur la machine | jamais déduite des fichiers | « Non détecté » tant que le CLI ne le voit pas |
| Fichiers de journaux illisibles | ignorés en silence par le CLI | rien : la dépense peut être partielle |
