# Agent Burn (app de bureau)

App de bureau **Windows et Linux** du module Quickshell **Agent Burn**, recréation de l'app macOS
[agent-burn](https://github.com/Melvynx/agent-burn) de Melvynx : dépense des agents de code (Claude Code, Codex
et les autres agents que le CLI reconnaît), jetons, modèles et **limites d'abonnement en direct**, dans une
**icône de la zone de notification**, un **aperçu** (popover), un **dashboard** et une fenêtre **Paramètres**.

Les chiffres viennent du CLI `agent-burn` (Rust, projet amont), embarqué dans l'app à la révision épinglée dans
[`install.sh`](../../install.sh) (`AB_REV` / `AB_VER`). Le cœur et les vues (aperçu, dashboard) sont les mêmes
fichiers QML que dans la barre Quickshell (`config/quickshell/`) : une couche de compatibilité PySide6 les fait
tourner tels quels.

Pour les développeurs : [architecture](docs/ARCHITECTURE.md), [fournisseurs](docs/PROVIDERS.md),
[suivi de l'amont](docs/UPSTREAM.md), [tests, build et release](docs/DEVELOPMENT.md).

## Plateformes

| Plateforme | Formats | Ce qui a réellement été vérifié |
|---|---|---|
| Windows 10 (1809 ou plus) et 11, x64 | installeur, zip portable | **Sous Wine 11 seulement** : tests unitaires (Python Windows), bundle, installeur installé, mis à jour puis désinstallé, selftest de l'app installée et du zip. Jamais sur un vrai Windows : le job Windows de la CI le fera, mais elle n'a encore jamais tourné. |
| Windows 11 ARM64 | installeur `arm64` expérimental, ou l'installeur x64 en émulation | Installeur arm64 compilé, jamais lancé sur une machine ARM. Émulation x64 non essayée. |
| Ubuntu 22.04 et 24.04, Debian 12 et 13 | `.deb` | Paquet installé, selftest de l'app installée (rendu logiciel, puis OpenGL Mesa sous Xvfb), désinstallation complète : dans un conteneur de chaque distro, sans session de bureau. |
| Fedora 44 | `.rpm` (dnf) | Comme ci-dessus. |
| openSUSE Tumbleweed | `.rpm` (zypper) | Comme ci-dessus. |
| Arch Linux | archive `.tar.gz`, AppImage | Comme ci-dessus (archive installée dans `/opt`, AppImage lancée sans FUSE). |
| Autre distro x86_64 avec glibc 2.35 ou plus | AppImage, archive | Non essayé. |
| KDE Plasma (Wayland, et X11 par Xwayland) | — | App lancée dans une session KWin imbriquée sans écran, avec un hôte de zone de notification de test : icône, clics, menu, panneau apparu après l'app. Jamais avec la vraie zone de notification de Plasma. |
| GNOME | — | GNOME 50 sans écran (conteneur), pendant l'audit, avec l'ancienne version de l'app : pas de zone de notification sans l'extension AppIndicator, une avec. L'app actuelle n'y a pas tourné. |
| XFCE, Cinnamon, Hyprland, autres | — | Non essayé. |
| EL9 (AlmaLinux, Rocky…) et toute glibc antérieure à 2.35 | — | Non pris en charge. |

Ces essais ont été faits pendant le développement, partie par partie. Sur la version intégrée, seuls les tests
Linux ont été relancés (tests unitaires, suite du cœur sous Quickshell et sous l'app, selftest en session
imbriquée). La CI rejoue tout à chaque run (tests, paquets sur 7 distros, installeur sur un vrai Windows) : ce
tableau sera à mettre à jour après son premier run.

## Installer

### Où trouver les fichiers

- **Release GitHub** du dépôt : créée en brouillon par la CI pour chaque tag `desktop-v<version>`, publiée à la
  main. Aucune n'est publiée à ce jour.
- **Artefacts de la CI** : onglet Actions → workflow « Agent Burn (bureau) » → un run réussi →
  `agent-burn-desktop-linux` ou `agent-burn-desktop-windows-x64` (gardés 1 jour).
- **Build local** : voir [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

Le dépôt est privé : il faut y avoir accès.

| Fichier | Pour |
|---|---|
| `AgentBurn-Setup-<version>-x64.exe` | Windows, installeur |
| `AgentBurn-portable-<version>-x64.zip` | Windows, sans installation |
| `agent-burn-desktop_<version>_amd64.deb` | Debian, Ubuntu |
| `agent-burn-desktop-<version>-1.x86_64.rpm` | Fedora, openSUSE |
| `agent-burn-desktop-<version>-x86_64.AppImage` | toute distro x86_64 récente |
| `agent-burn-desktop-<version>-x86_64.tar.gz` | Arch, ou installation à la main |
| `SHA256SUMS` | contrôle : `sha256sum -c --ignore-missing SHA256SUMS` (Windows : `Get-FileHash <fichier>`) |

### Windows

1. Lancer `AgentBurn-Setup-<version>-x64.exe` : installation pour l'utilisateur seul, sans droits
   administrateur, dans `%LOCALAPPDATA%\Programs\Agent Burn`, raccourci dans le menu Démarrer. Deux cases :
   « Lancer Agent Burn au démarrage de Windows » (cochée) et « Créer un raccourci sur le Bureau » (décochée).
   L'app se lance à la fin.
2. **SmartScreen** : l'installeur n'est pas signé. « Windows a protégé votre ordinateur » →
   **Informations complémentaires** → **Exécuter quand même**.
3. Mise à jour : lancer l'installeur d'une version plus récente. Il ferme l'app si elle tourne, remplace
   l'installation et garde données et réglages. Pas de mise à jour automatique.

Sans installation : dézipper `AgentBurn-portable-<version>-x64.zip` où l'on veut et lancer
`AgentBurn\AgentBurn.exe`. Données et réglages vont quand même dans `%APPDATA%\AgentBurn`, cache et journaux
dans `%LOCALAPPDATA%\AgentBurn`.

### Linux

Formats x86_64, glibc 2.35 ou plus récente (Ubuntu 22.04, Debian 12, Fedora, openSUSE Tumbleweed, Arch…).

```sh
sudo apt install ./agent-burn-desktop_<version>_amd64.deb                              # Debian, Ubuntu
sudo dnf install ./agent-burn-desktop-<version>-1.x86_64.rpm                           # Fedora
sudo zypper install --allow-unsigned-rpm ./agent-burn-desktop-<version>-1.x86_64.rpm   # openSUSE
```

Les paquets ne sont pas signés. Ils posent l'app dans `/opt/agent-burn-desktop` (avec son propre CLI dans
`bin/`, sans conflit avec un `agent-burn` installé à part), la commande `agent-burn-desktop`, l'entrée de menu
« Agent Burn », les icônes et les métadonnées AppStream. Paquets recommandés : une police (DejaVu) et Mesa
(OpenGL).

**AppImage** :

```sh
chmod +x agent-burn-desktop-<version>-x86_64.AppImage
./agent-burn-desktop-<version>-x86_64.AppImage
```

Elle a besoin de FUSE. Sans FUSE : `./agent-burn-desktop-<version>-x86_64.AppImage --appimage-extract-and-run`
(ou la variable `APPIMAGE_EXTRACT_AND_RUN=1`). Pas d'entrée de menu. Le lancement à l'ouverture de session
pointe sur le fichier AppImage : après l'avoir déplacé, réactiver l'option.

**Archive** : décompresser et lancer, sans rien installer.

```sh
tar -xzf agent-burn-desktop-<version>-x86_64.tar.gz
./agent-burn-desktop-<version>-x86_64/agent-burn-desktop
```

Intégration au menu (facultatif), comme le fait le test des paquets sous Arch :

```sh
V=agent-burn-desktop-1.0.0-x86_64    # nom de l'archive sans .tar.gz
sudo mkdir /opt/agent-burn-desktop
sudo tar -xzf $V.tar.gz -C /opt/agent-burn-desktop --strip-components=1 --exclude=$V/share
sudo ln -s /opt/agent-burn-desktop/agent-burn-desktop /usr/local/bin/agent-burn-desktop
sudo tar -xzf $V.tar.gz -C /usr/local --strip-components=1 $V/share
```

Dépendances sous Arch :
`sudo pacman -S --needed fontconfig freetype2 libdrm libglvnd libx11 libxcb libxkbcommon libxkbcommon-x11 wayland mesa ttf-dejavu`.

### Depuis les sources

Python 3.12 et PySide6 6.12 : voir [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Prérequis

- Claude Code et/ou Codex utilisés sur cette machine, avec ce compte : le CLI lit leurs journaux locaux. Rien
  d'autre à installer : le CLI `agent-burn`, Python et Qt sont dans l'app.
- Limites Claude en direct : Claude Code connecté (`claude` puis `/login`) et le réseau.
- Limites Codex : lues dans les journaux de session de Codex, ou en direct quand Codex est connecté et le
  réseau présent.
- Pour l'icône : une zone de notification (Windows ; KDE ; GNOME avec l'extension AppIndicator). Sans elle,
  l'app fonctionne en fenêtre seule.

## Premier lancement

- Windows : l'installeur lance l'app. L'icône apparaît dans la zone de notification, parfois rangée derrière
  la flèche **^** : la glisser sur la barre des tâches.
- Linux : entrée « Agent Burn » du menu, ou `agent-burn-desktop`.
- Le premier rapport arrive quelques secondes après le lancement (plus longtemps hors ligne). Aux lancements
  suivants, le dernier rapport est affiché tout de suite, marqué « En cache », jusqu'au nouveau.
- Sans zone de notification, le dashboard s'ouvre. L'app réessaie de poser son icône toutes les 5 s pendant
  2 min (cas du panneau lancé après elle à l'ouverture de session).
- Relancer l'app alors qu'elle tourne ouvre son dashboard : une seule instance par utilisateur et par session.

## Icône de la zone de notification

L'icône montre le % restant de la limite la plus serrée sur une pastille teintée selon le rythme (grise :
relevé ancien), ou une flamme grise tant qu'il n'y a pas de données. Au survol : la limite et son
réinitialisation, ou l'état des données.

| | Windows | Linux X11 | Linux Wayland |
|---|---|---|---|
| Clic gauche | aperçu, posé contre l'icône (près du pointeur si elle est rangée derrière la flèche) | aperçu, près du pointeur (le panneau ne dit pas où est l'icône) | dashboard (le compositeur placerait l'aperçu lui-même, souvent au centre) |
| Double clic | dashboard (l'aperçu ouvert par le 1er clic se ferme) | — | — |
| Clic du milieu | rafraîchir | rafraîchir | rafraîchir |
| Clic droit | menu | menu, dessiné par le panneau | menu, dessiné par le panneau |

L'action du clic gauche se change dans Paramètres → Général → « Clic sur l'icône ».

Menu de l'icône :

- 1 à 3 lignes d'état, non cliquables : les limites les plus serrées (« Claude Code · Semaine : 25 % restant ·
  réinit. dans 1 j 20 h », suivi de « · ancien » si le relevé est vieux) ; sans limite, l'état de Claude Code et
  de Codex (« Codex : Non détecté ») ; sans données, « Données indisponibles ». Sous Wayland, ce sont les seules
  informations affichées contre l'icône.
- Ouvrir l'aperçu, Ouvrir le dashboard, Rafraîchir, Lancer à l'ouverture de session (case à cocher, absente
  du lancement depuis les sources), Paramètres…, Journaux (ouvre le dossier des journaux), À propos, Quitter.

Selon le bureau :

- Windows : zone de notification native.
- Linux : protocole StatusNotifierItem (KDE Plasma, GNOME avec l'extension AppIndicator, XFCE, Cinnamon…).
  Seul un hôte de test façon KDE a été essayé, en session imbriquée.
- GNOME sans l'extension AppIndicator / KStatusNotifierItem : pas de zone de notification. L'app tourne en
  fenêtre seule, fermer le dashboard la quitte, et Paramètres → Général le dit. Ubuntu active cette extension
  par défaut, Fedora la fournit désactivée (non vérifié ici).

Fermer les fenêtres : avec une icône, fermer le dashboard laisse l'app dans la zone de notification (option
« Garder dans la zone de notification à la fermeture », activée par défaut). Option désactivée, fermer le
dashboard quitte l'app. Sans icône, fermer la dernière fenêtre la quitte. Sinon : menu → Quitter.

## Aperçu

Carte posée contre l'icône (Windows) ou près du pointeur (X11), fermée par Échap, par « Ouvrir le dashboard » ou
par un clic ailleurs.

- Onglet **Général** : dépense totale (tous agents, équivalent API), jetons, dépense du jour, une ligne par
  agent, graphe des 14 derniers jours.
- Un onglet **par agent qui a des limites** (Claude Code, Codex…) : état du fournisseur, dépense des 30
  derniers jours, forfait mensuel, % restant de la limite hebdomadaire en grand, puis les autres limites
  (session de 5 h, limites par modèle), verdict de rythme (« De la marge pour continuer », « Rythme un peu trop
  rapide » avec l'heure d'épuisement estimée et le rythme à tenir, « Limite atteinte ») et graphe des relevés
  avec leur prévision.
- En bas : état des données (« En direct · mis à jour il y a 2 min »), l'erreur du CLI s'il y en a une, bouton
  « Ouvrir le dashboard ». Le bouton de rafraîchissement est en haut à droite.

## Dashboard

- Barre latérale : **Tous les agents**, une page par agent, **Paramètres** en bas. Période en haut : Tout,
  30 jours, 7 jours, Aujourd'hui.
- **Tous les agents** : dépense totale, jetons, jours enregistrés, modèles ; carte **Fournisseurs** (Claude Code
  et Codex, puis les agents détectés, avec leur état) ; dépense journalière ; dépense par agent ; tableau des
  modèles (filtre, tri par colonne).
- **Page d'un agent** : état, avertissements (erreur du CLI, erreur propre à cet agent, explication de l'état
  s'il n'est pas « En direct », tarifs manquants), forfait (une jauge par limite, crédits supplémentaires de
  Claude), économie du forfait et répartition par type de jeton sur 30 jours (Claude Code et Codex), dépense
  journalière, modèles.
- **Historique journalier** : Claude Code efface ses journaux de plus de 30 jours ; l'app garde chaque jour vu,
  même après une mise à jour ou une désinstallation. « Afficher la sauvegarde » ouvre le dossier des données.
- Échap ferme la fenêtre.

## Paramètres

Menu de l'icône → Paramètres…, ou bouton Paramètres du dashboard. Chaque changement est enregistré tout de
suite. Échap ferme la fenêtre (une liste ouverte d'abord).

| Section | Réglage | Valeurs (défaut) | Effet |
|---|---|---|---|
| Général | Rafraîchissement automatique | 1, 5, 15 ou 30 min (5) | Limites relevées à ce rythme, rapport complet au moins une fois par heure (à chaque tour si la limite la plus serrée n'est pas une fenêtre Claude). Le dashboard ouvert se recharge au même rythme. |
| | Thème | Système, Clair, Sombre (Système) | Système suit le clair/sombre du bureau (sous Linux, par xdg-desktop-portal). |
| | Lancer à l'ouverture de session | oui / non (non, sauf case de l'installeur Windows cochée) | Pas depuis les sources. Windows : valeur `AgentBurn` de `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (une désactivation faite dans le Gestionnaire des tâches est respectée ; réactiver l'option l'annule). Linux : `~/.config/autostart/io.github.magikdidi24.AgentBurn.desktop`, `Hidden=true` vaut désactivé ; seul ce fichier est créé ou retiré. |
| | Garder dans la zone de notification à la fermeture | oui / non (oui) | Non : fermer le dashboard quitte l'app. |
| | Clic sur l'icône | Aperçu, Dashboard (Dashboard sous Wayland, Aperçu ailleurs) | Action du clic gauche. |
| Fournisseurs | — | — | Claude Code, Codex, puis chaque autre agent vu : état, explication, âge du relevé, dernière erreur propre à l'agent. CLI agent-burn : emplacement, version, état du rapport, bouton « Rafraîchir maintenant ». |
| Diagnostic | — | — | Versions (app, CLI, CLI prévu par le build), système, affichage, écrans, zone de notification, dossiers. Boutons « Ouvrir les journaux », « Ouvrir le dossier des données », « Copier le diagnostic ». Interrupteur « Journal détaillé (débogage) », sans redémarrer. Dernières erreurs (heure, origine, message). Bouton « Réinitialiser les paramètres ». |
| À propos | — | — | Versions, crédit, bouton « Licences » (app installée). |

Les réglages sont dans `settings.json` (voir [Où sont les fichiers](#où-sont-les-fichiers)) : `refreshMinutes`,
`theme`, `closeToTray`, `trayClick`, `debugLogging`. Une valeur invalide reprend son défaut (noté dans le
journal). Un fichier illisible est copié en `settings.json.bak`, les défauts s'appliquent et Diagnostic
l'annonce. Le lancement à l'ouverture de session n'y est pas : il est lu dans le système.

## État des données

Affiché en bas de l'aperçu et du dashboard, dans Paramètres → Fournisseurs, et dans la bulle de l'icône quand
aucune limite n'est relevée.

| État | Quand | Que faire |
|---|---|---|
| **En direct** | Le dernier rapport du CLI a réussi il y a moins d'une heure (plus un tour de rafraîchissement). | Rien. |
| **En cache** | Rapport relu sur le disque au lancement, en attendant le premier run ; ou dernier run en échec (erreur du CLI, pas de réponse en 120 s, rapport illisible, CLI absent) ; ou rapport trop vieux. Les derniers chiffres restent affichés. | Rafraîchir. Si ça dure, lire l'erreur (bas de l'aperçu, Paramètres → Diagnostic → Dernières erreurs). |
| **Indisponible** | Aucun rapport réussi, même ancien. | Attendre le premier rapport, sinon voir [Dépannage](#dépannage). |

## État de chaque fournisseur

Affiché sur l'onglet de l'agent, en tête de sa page du dashboard, dans la carte Fournisseurs, dans Paramètres →
Fournisseurs et dans le menu de l'icône quand il n'y a pas de limite. Détail des signaux dans
[docs/PROVIDERS.md](docs/PROVIDERS.md).

| Libellé | Signifie | Que faire |
|---|---|---|
| **En direct** | Limites relevées récemment : sur le compte Claude depuis moins de 10 min ; pour les autres agents, dans le dernier rapport, lui-même en direct. | Rien. |
| **Relevé ancien** | Dernières limites connues, gardées à l'écran : Claude n'a pas été relevé depuis plus de 10 min (réseau, API d'usage qui refuse les appels trop fréquents) ; pour les autres, rapport en cache. | Rafraîchir, vérifier le réseau. |
| **Connexion à vérifier** | Claude seulement : le renouvellement de la connexion a été refusé. Soit la connexion a expiré, **soit** le réseau était coupé alors que le jeton avait expiré (sortie de veille avant le Wi-Fi) : le CLI ne fait pas la différence. | Vérifier le réseau, puis Rafraîchir. Si ça persiste avec le réseau : `claude` dans un terminal, puis `/login`. |
| **Usage local** | Dépense lue dans les journaux, pas de limites. Claude : non connecté ou hors ligne (le CLI ne dit pas lequel). Autres : pas de limite dans le rapport, ou limites de plus de 7 jours (vieux journaux Codex), écartées. | Claude : se connecter, vérifier le réseau. Codex : une session Codex récente remet ses limites à jour. |
| **Non détecté** | Le CLI ne trouve ni usage ni abonnement pour cet agent. | Normal si l'agent ne sert pas sur cette machine avec ce compte. |
| **Inconnu** | Pas encore de rapport. | Attendre quelques secondes. |
| **CLI introuvable** | Le CLI embarqué ne se lance pas. | Voir [CLI introuvable](#cli-introuvable). |

## Où sont les fichiers

| | Windows | Linux |
|---|---|---|
| App | `%LOCALAPPDATA%\Programs\Agent Burn` (installeur), ou le dossier du zip | `/opt/agent-burn-desktop` (paquets), le fichier AppImage, ou le dossier de l'archive |
| CLI embarqué | `bin\agent-burn.exe` dans le dossier de l'app | `bin/agent-burn` dans le dossier de l'app |
| Données | `%APPDATA%\AgentBurn` | `~/.local/share/agent-burn-desktop` (`$XDG_DATA_HOME`) |
| Réglages | `%APPDATA%\AgentBurn\settings.json` | `~/.config/agent-burn-desktop/settings.json` (`$XDG_CONFIG_HOME`) |
| Journaux | `%LOCALAPPDATA%\AgentBurn\logs` | `~/.local/state/agent-burn-desktop/logs` (`$XDG_STATE_HOME`) |
| Cache | `%LOCALAPPDATA%\AgentBurn\cache` | `~/.cache/agent-burn-desktop` et `~/.cache/AgentBurn/qmlcache` (`$XDG_CACHE_HOME`) |
| Lancement à l'ouverture de session | valeur `AgentBurn` de `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` | `~/.config/autostart/io.github.magikdidi24.AgentBurn.desktop` |
| Instance unique | tube nommé `\\.\pipe\AgentBurn-<utilisateur>-<session>` | `$XDG_RUNTIME_DIR/AgentBurn.sock` |
| Cache du CLI lui-même | `%USERPROFILE%\.cache\agent-burn` | `~/.cache/agent-burn` |

Dossier des données :

- `burn-history.json` : archive journalière (coût et jetons par jour et par agent) ;
- `burn-quota.json` : dernier relevé du compte Claude et relevés des limites des 8 derniers jours (graphes) ;
- `burn-summary.json` : dernier rapport réussi, affiché « En cache » au lancement ;
- `*.bak` : copie d'un de ces fichiers trouvé illisible, l'app repartant alors de zéro pour lui ;
- `agent-burn-cli.json` n'existe jamais : c'est la configuration vide passée au CLI (voir plus bas).

Journaux : `agent-burn.log`, tourné à 1 Mo avec 3 copies (`.1` à `.3`), une ligne par événement
(`<heure ISO> <niveau> <logger> : <message>`). Cache : copie préparée des QML (`qml-<empreinte>`, revérifiée à
chaque lancement) et cache compilé de Qt. La variable `AGENT_BURN_DATA` remplace le dossier des données (tests).

## Vie privée : ce que l'app lit et écrit

- **L'app ne fait aucun appel réseau.** Elle lance le CLI `agent-burn` embarqué (arguments passés directement,
  jamais par un shell), un run de chaque sorte à la fois, et lit sa sortie JSON.
- **Le CLI lit** les journaux et la configuration de Claude Code (`~/.claude/projects`, `~/.claude.json`), son
  jeton de connexion (`~/.claude/.credentials.json`) pour relever les limites, les journaux de Codex
  (`~/.codex/sessions`, `~/.codex/archived_sessions`) et son jeton (`~/.codex/auth.json`), et les dossiers des
  autres agents. Sous Windows, ces chemins sont sous `%USERPROFILE%` : l'app impose `HOME=%USERPROFILE%` au
  CLI, qui sinon suivrait un `HOME` défini ailleurs (Git Bash par exemple).
- **Le CLI écrit** : quand le jeton OAuth de Claude a expiré, il le renouvelle et **réécrit
  `~/.claude/.credentials.json`**, comme Claude Code (verrous temporaires dans `~/.claude`) ; et son cache
  `claude-usage.json`.
- **Le CLI contacte** : les tarifs (LiteLLM sur raw.githubusercontent.com, models.dev), `api.anthropic.com`
  (limites Claude), `platform.claude.com` (renouvellement du jeton), `chatgpt.com` (limites Codex, si Codex est
  connecté).
- **La configuration agent-burn de l'utilisateur est ignorée exprès** : chaque run reçoit
  `--config <dossier des données>/agent-burn-cli.json`, un fichier jamais créé. `./.agent-burn/`,
  `~/.config/agent-burn/agent-burn.json` et `~/.claude/agent-burn.json` (`noCost`, `jq`, `offline`…) n'ont donc
  aucun effet, pas plus que `AGENT_BURN_FORCE_REFRESH`, `AGENT_BURN_QUOTA_ONLY` ou `LOG_LEVEL` hérités. Le CLI
  tourne dans le dossier des données. Les chiffres sont ainsi ceux du CLI par défaut, quelle que soit la
  configuration de la machine.
- **L'app écrit** seulement ses dossiers (tableau ci-dessus), l'entrée de lancement à l'ouverture de session
  quand l'option est active, et son point d'instance unique. L'usage (coûts, jetons, modèles, forfait) y est
  stocké en clair.
- **Journaux** : ligne de commande de chaque run du CLI (avec les chemins), code de sortie, durée, taille de la
  sortie, la ligne `Error:` du CLI en cas d'échec ; jamais le rapport lui-même. Aussi les messages Qt et QML et
  les erreurs Python avec leur trace. Masqués en `[masqué]` : jetons `sk-ant-…`, valeurs `Bearer`, JWT, valeurs
  de jetons access/refresh/id, adresses e-mail, longues chaînes hexadécimales ou base64 (UUID de chemins compris).
- **Diagnostic copié** : mêmes masques, aucune variable d'environnement ni contenu de fichier. Il contient les
  chemins des dossiers, donc le nom d'utilisateur.

## Dépannage

### Pas d'icône dans la zone de notification

- Windows : l'icône est peut-être derrière la flèche **^** de la barre des tâches : l'en sortir par
  glisser-déposer.
- GNOME : installer et activer l'extension AppIndicator (déjà active sous Ubuntu). Paramètres → Général le
  signale quand aucune zone de notification n'est détectée.
- Panneau lancé après l'app : elle réessaie pendant 2 min ; au-delà, la relancer.
- Paramètres → Diagnostic → « Zone de notification » dit ce que l'app a trouvé. Sans icône, tout reste
  accessible par le dashboard.

### L'aperçu s'ouvre au centre de l'écran (Wayland)

Normal : sous Wayland, le compositeur ignore la position demandée par l'app. Le clic gauche ouvre donc le
dashboard par défaut, et les lignes en tête du menu donnent les limites. L'aperçu reste dans le menu (« Ouvrir
l'aperçu ») et peut redevenir l'action du clic (Paramètres → Général → Clic sur l'icône).

### Connexion à vérifier

Le CLI a vu le renouvellement de la connexion Claude refusé. Il envoie le même signal pour une connexion
expirée et pour un jeton expiré sans réseau. Vérifier le réseau, puis **Rafraîchir** : après un refus, le CLI
attend 10 min avant de réessayer, et Rafraîchir force un nouvel essai. Si ça persiste avec le réseau, lancer
`claude` dans un terminal puis `/login`. Les dernières limites connues restent affichées, marquées anciennes.

### Tarifs indisponibles

Bandeau « Tarifs indisponibles : montants incomplets (réseau coupé ou tarifs non téléchargés) » : le CLI n'a pas
pu télécharger les prix (hors ligne, LiteLLM injoignable), et ses prix intégrés ne connaissent pas les modèles
récents, comptés à 0 $. L'app affiche « — » plutôt que 0,00 $ et l'archive garde le coût déjà connu des jours
passés. Revenir en ligne, puis Rafraîchir. Hors ligne, un rapport demande aussi beaucoup plus de calcul.

### CLI introuvable

Message de l'app : « Agent Burn ne trouve pas son CLI (<chemin>) : réinstalle l'application. »

- Le CLI est `bin\agent-burn.exe` (Windows) ou `bin/agent-burn` (Linux) dans le dossier de l'app. Paramètres →
  Fournisseurs → CLI agent-burn donne son emplacement et sa version.
- Windows : un antivirus a pu le mettre en quarantaine. Le restaurer, ou réinstaller.
- Une variable `AGENT_BURN_BIN` définie dans l'environnement remplace ce chemin : la retirer.

Autres erreurs du CLI, affichées telles quelles :

- « agent-burn a échoué (code 1) : … » suit le message du CLI. Par exemple « No valid Claude data directories
  found in CLAUDE_CONFIG_DIR » : la variable `CLAUDE_CONFIG_DIR` pointe vers un dossier sans `projects/`, ce qui
  fait échouer tout le rapport, Codex compris. La corriger ou la retirer.
- « CLI agent-burn incompatible » (code 2) : le CLI refuse une option ; il ne correspond pas à la version prévue
  par l'app (réinstaller, ou retirer `AGENT_BURN_BIN`).
- « agent-burn n'a pas répondu en 120 s » : run arrêté. Possible hors ligne avec un gros historique (calcul des
  prix sans tarifs téléchargés).
- « Rapport illisible renvoyé par agent-burn. » : sortie qui n'est pas un rapport. Joindre le diagnostic à un
  signalement.

### SmartScreen, antivirus

Ni l'installeur ni l'app ne sont signés : SmartScreen avertit au premier lancement (« Informations
complémentaires » → « Exécuter quand même »), et des antivirus se méfient des exécutables PyInstaller. Vérifier
d'abord le fichier contre `SHA256SUMS`. Si l'antivirus retire `bin\agent-burn.exe`, l'app affiche « CLI
introuvable ».

### Mauvais thème

- Paramètres → Général → Thème : Clair ou Sombre imposent le thème.
- Linux, avec Système : le thème est lu par xdg-desktop-portal. Sans portail, l'app ne connaît pas le thème du
  bureau et prend le sombre. Si `QT_QPA_PLATFORMTHEME` est défini, l'app utilise ce module Qt à la place du
  portail.
- Windows : l'app suit le mode clair/sombre des applications et la couleur d'accentuation.

### Recueillir un diagnostic

- Paramètres → Diagnostic → **Copier le diagnostic** : versions, système, dossiers, état de chaque fournisseur,
  dernières erreurs. À coller dans un signalement.
- Journaux : menu de l'icône → Journaux, ou Paramètres → Diagnostic → Ouvrir les journaux. Pour plus de
  détails, activer « Journal détaillé (débogage) », reproduire, puis joindre `agent-burn.log`.

### Réinitialiser les réglages

Paramètres → Diagnostic → **Réinitialiser les paramètres** (le lancement à l'ouverture de session ne change
pas). Ou supprimer `settings.json`, app fermée. Pour tout effacer, supprimer aussi le dossier des données :
l'historique est alors perdu.

## Désinstaller

| Format | Désinstaller | Ce qui reste |
|---|---|---|
| Installeur Windows | Paramètres → Applications → Applications installées → Agent Burn → Désinstaller. Arrête l'app (toute instance `AgentBurn.exe` de l'utilisateur, copie portable comprise), retire le dossier, les raccourcis, le lancement à l'ouverture de session, le cache et les journaux. | `%APPDATA%\AgentBurn` (historique, réglages), que retrouve une réinstallation. |
| Zip portable | Désactiver « Lancer à l'ouverture de session », quitter, supprimer le dossier. | `%APPDATA%\AgentBurn`, `%LOCALAPPDATA%\AgentBurn`. |
| `.deb`, `.rpm` | Désactiver le lancement à l'ouverture de session, quitter, puis `sudo apt remove agent-burn-desktop`, `sudo dnf remove agent-burn-desktop` ou `sudo zypper remove agent-burn-desktop`. | Les dossiers de l'utilisateur (données, réglages, journaux, cache). |
| AppImage | Désactiver le lancement à l'ouverture de session, quitter, supprimer le fichier. | Idem. |
| Archive | Désactiver le lancement à l'ouverture de session, quitter, supprimer le dossier. Installée comme plus haut : `sudo rm -r /opt/agent-burn-desktop /usr/local/bin/agent-burn-desktop` et les fichiers `io.github.magikdidi24.AgentBurn.*` copiés sous `/usr/local/share` (`applications/`, `metainfo/`, `icons/hicolor/*/apps/`). | Idem. |

Sous Linux, un lancement à l'ouverture de session resté actif laisse
`~/.config/autostart/io.github.magikdidi24.AgentBurn.desktop` : le supprimer. Tout effacer :
`rm -r ~/.local/share/agent-burn-desktop ~/.config/agent-burn-desktop ~/.local/state/agent-burn-desktop ~/.cache/agent-burn-desktop ~/.cache/AgentBurn`
(Windows : supprimer `%APPDATA%\AgentBurn` et `%LOCALAPPDATA%\AgentBurn`). Le cache du CLI
(`~/.cache/agent-burn`) appartient au CLI et peut servir à un autre `agent-burn` : il n'est jamais touché.

## Limites connues

- Aucun essai sur un vrai Windows tant que la CI n'a pas tourné (voir [Plateformes](#plateformes)).
- Non signé (SmartScreen, antivirus). Pas de mise à jour automatique.
- Wayland : aperçu placé par le compositeur. GNOME : zone de notification seulement avec l'extension AppIndicator.
- Linux : pas de détection d'inactivité, les relevés continuent quand la session est inactive (Windows les
  suspend après 5 min sans saisie).
- Codex n'a été vu que sur des données de test (synthétiques ou nettoyées), jamais avec un vrai compte Codex.
- Hors Claude, les fenêtres de limite sont supposées de 5 h et de 7 jours.
- Lecteurs d'écran : noms accessibles et navigation au clavier en place, jamais essayés avec Orca ou Narrateur.
- Windows : barre de titre sombre non vérifiée (Wine ne l'applique pas), sans effet attendu avant Windows 10
  20H1.
- Taille : environ 200 Mo installés sous Linux ; installeur Windows d'environ 45 Mo.
- Linux x86_64 seulement, glibc 2.35 ou plus. Windows ARM64 expérimental.
- Le CLI est arrêté s'il dépasse 120 s, à la fermeture de l'app et par l'installeur. S'il réécrivait à cet
  instant le jeton de Claude, Claude Code pourrait redemander `/login` (risque lu dans le code du CLI, jamais
  observé).

## Licences

- **Agent Burn (cette app)** : MIT, [LICENSE](LICENSE).
- **CLI `agent-burn`** (embarqué) : MIT, © ryoppippi et Melvynx. Les licences des crates Rust liées dans le
  binaire, texte compris, sont dans `THIRD-PARTY-NOTICES.txt`.
- **Qt 6, PySide6, Shiboken6** : LGPL-3.0, utilisés sans modification. Ce sont des bibliothèques partagées
  séparées (dossier `PySide6/` de l'app ; sous Linux, aussi les liens `lib*.so.6` à sa racine) : on peut les
  remplacer par une version modifiée compatible sans recompiler l'app (LGPL-3.0, section 4 d) 1)). Notice et
  liens vers les sources : `NOTICE-Qt-PySide6.txt` ; textes : `LGPL-3.0.txt`, `GPL-3.0.txt`.
- **JetBrainsMono Nerd Font** : SIL Open Font License 1.1.
- **Python** : licence PSF, avec les bibliothèques C de sa distribution.
- Linux : notices Debian des bibliothèques système embarquées (`licenses/debian/`).

Tous ces textes sont dans le dossier `licenses/` à côté de l'exécutable, qu'ouvre Paramètres → À propos →
Licences.

Merci à Melvynx pour [agent-burn](https://github.com/Melvynx/agent-burn) : l'app Mac a servi de modèle, et son
CLI fait toute la lecture des journaux, le calcul des prix et le relevé des limites.
