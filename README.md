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
| Windows 10 (1809 ou plus) et 11, x64 | installeur, zip portable | **Sous Wine 11 seulement, jamais sur un vrai Windows.** Au commit `8603950` : bundle et installeur construits (CLI compilé avec mingw ; les builds le compilent avec MSVC), selftest de l'app gelée, 43 contrôles sur 43 réussis pour l'installation, la mise à jour, la désinstallation et le zip portable. Après les correctifs : bundle refait et selftest réussi, installeur rejoué dans un dossier déjà occupé (rien d'effacé) et en mise à jour. Tests unitaires sous Python Windows : pendant le développement. Le job Windows de la CI fera le vrai essai. |
| Windows 11 ARM64 | installeur `arm64` expérimental, ou l'installeur x64 en émulation | Installeur arm64 compilé, jamais lancé sur une machine ARM. Émulation x64 non essayée. |
| Ubuntu 22.04 et 24.04, Debian 12 et 13 | `.deb` | Paquets construits au commit `8603950`, puis installés, selftest de l'app installée (rendu logiciel, puis OpenGL Mesa sous Xvfb) et désinstallation complète : dans un conteneur de chaque distro, sans session de bureau. Après les correctifs des paquets (licences, fichier `copyright`), refait sur Ubuntu 24.04 et Debian 12. |
| Fedora 44 | `.rpm` (dnf) | Comme ci-dessus, refait aussi après les correctifs. |
| openSUSE Tumbleweed | `.rpm` (zypper) | Comme ci-dessus, au commit `8603950` seulement. |
| Arch Linux | archive `.tar.gz`, AppImage | Comme ci-dessus, au commit `8603950` seulement (archive installée dans `/opt`, AppImage lancée sans FUSE). |
| Autre distro x86_64 avec glibc 2.35 ou plus | AppImage, archive | Non essayé. |
| KDE Plasma (Wayland, et X11 par Xwayland) | — | App gelée (archive du commit `8603950`) dans une session KWin imbriquée sans écran, sous Wayland et sous Xwayland, avec un hôte de zone de notification de test : icône, clic, menu (Paramètres…, Journaux, Quitter), aperçu placé sous X11 ; sans hôte, dashboard puis sortie à sa fermeture. Pendant les correctifs, depuis les sources : hôte apparu 130 s après l'app, hôte disparu, Quitter pendant un run du CLI. Jamais avec la vraie zone de notification de Plasma. |
| GNOME | — | GNOME 50 sans écran (conteneur), pendant l'audit, avec l'ancienne version de l'app : pas de zone de notification sans l'extension AppIndicator, une avec. L'app actuelle n'y a pas tourné. |
| XFCE, Cinnamon, Hyprland, autres | — | Non essayé. |
| EL9 (AlmaLinux, Rocky…) et toute glibc antérieure à 2.35 | — | Non pris en charge. |

Le commit `8603950` est la version intégrée avant la revue du code ; les correctifs de la revue sont arrivés
ensuite. Sur la version corrigée, ont été relancés sous Linux, depuis les sources : tests unitaires (115), suite
du cœur sous Quickshell 0.3.2 et sous l'app (274 contrôles, 27 avec des fichiers corrompus, 6 avec un CLI
bloqué), selftests, et en session imbriquée l'icône (Wayland et Xwayland) et Quitter pendant un run du CLI. Les
paquets et le bundle Windows refaits « après les correctifs » ne portaient que ceux des paquets : aucun n'a encore
été construit depuis la version corrigée complète. La CI est écrite et passe actionlint, mais n'a encore jamais
tourné : son premier run, au prochain push, rejouera tout (tests, paquets sur 7 distros, installeur sur un vrai
Windows), et ce tableau sera à mettre à jour.

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
4. Dossier choisi à la main : l'installeur ne vide ses sous-dossiers (`bin`, `licenses`, `PySide6`…) que
   par-dessus une installation d'Agent Burn (`AgentBurn.exe` et `unins000.dat` présents). Un dossier qui
   contient autre chose garde ses fichiers.

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
- Sans zone de notification, le dashboard s'ouvre. L'app revérifie toutes les 5 s, tant qu'elle tourne : un
  panneau lancé après elle, ou l'extension AppIndicator activée plus tard, reçoit l'icône sans relancer l'app.
- Relancer l'app alors qu'elle tourne ouvre son dashboard : une seule instance par utilisateur et par session.
  Deux lancements simultanés ne font pas deux instances : un verrou les départage, et le second essaie pendant
  3 s environ de joindre le premier (qui ouvre alors son dashboard), puis s'arrête.

## Icône de la zone de notification

L'icône montre le % restant de la limite la plus serrée sur une pastille teintée selon le rythme (grise :
relevé ancien), ou une flamme grise tant qu'il n'y a pas de données. Au survol : la limite et sa
réinitialisation ; sans limite, l'état des données et sa cause (CLI introuvable, lecture en cours, « échec du CLI
(voir Paramètres › Diagnostic) »).

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
  de Codex (« Codex : Non détecté ») ; sans données, « Données indisponibles », suivi de la cause s'il y en a une
  (« : échec du CLI (voir Paramètres › Diagnostic) » par exemple). Sous Wayland, ce sont les seules informations
  affichées contre l'icône.
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
dashboard quitte l'app, une fois Paramètres fermé aussi s'il était ouvert (rouvrir le dashboard entre-temps
annule). Sans icône, fermer la dernière fenêtre la quitte, y compris quand la zone de notification disparaît en
cours de route (panneau arrêté) : l'app le voit dans les 5 s. Sinon : menu → Quitter. En sortant, l'app attend
jusqu'à 5 s la fin d'un run du CLI en cours.

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
- Écran trop bas pour la carte : elle défile, et Tab l'amène au contrôle atteint ; Page précédente, Page
  suivante, Début et Fin la font défiler.

## Dashboard

- Barre latérale : **Tous les agents**, une page par agent, **Paramètres** en bas. Période en haut : Tout,
  30 jours, 7 jours, Aujourd'hui (la période choisie en gras et en couleur).
- **Tous les agents** : dépense totale, jetons, jours enregistrés, modèles ; carte **Fournisseurs** (Claude Code
  et Codex, puis les agents détectés, avec leur état) ; dépense journalière ; dépense par agent ; tableau des
  modèles (filtre, tri par colonne).
- **Page d'un agent** : état, avertissements (erreur du CLI, erreur propre à cet agent, explication de l'état
  s'il n'est pas « En direct », tarifs manquants), forfait (une jauge par limite, crédits supplémentaires de
  Claude), économie du forfait et répartition par type de jeton sur 30 jours (Claude Code et Codex), dépense
  journalière, modèles.
- **Historique journalier** : Claude Code efface ses journaux de plus de 30 jours ; l'app garde chaque jour vu,
  même après une mise à jour ou une désinstallation. « Afficher la sauvegarde » ouvre le dossier des données.
- Clavier : Tab parcourt les contrôles et la page (ou la liste « Par agent ») défile jusqu'au contrôle atteint ;
  Page précédente, Page suivante, Début et Fin font défiler la page. Échap dans « Filtrer les modèles » vide le
  filtre ; un 2e Échap, ou Échap ailleurs, ferme la fenêtre.
- Taille : 1200 × 800, réduite sur un petit écran sans passer sous 900 × 600 ; sur un écran plus petit encore,
  la fenêtre prend la place disponible et son contenu défile. À 900 × 600, un titre de carte perd sa précision
  grise (« 30 derniers jours ») quand les deux ne tiennent pas sur la ligne.

## Paramètres

Menu de l'icône → Paramètres…, ou bouton Paramètres du dashboard. Chaque changement est enregistré tout de
suite. Échap ferme la fenêtre (une liste ouverte d'abord).

Clavier : Tab passe d'un contrôle à l'autre (la page défile jusqu'à lui), Espace ou Entrée l'active (bouton,
interrupteur, option, onglet), flèche gauche ou droite passe à l'option voisine d'une rangée et la coche. Le
contrôle atteint au clavier porte un anneau de la couleur d'accent ; l'onglet de la section courante est en gras
et souligné. Ouverte sur une section depuis le menu de l'icône (Paramètres…, À propos), la fenêtre met le focus
sur son onglet.

| Section | Réglage | Valeurs (défaut) | Effet |
|---|---|---|---|
| Général | Rafraîchissement automatique | 1, 5, 15 ou 30 min (5) | Limites relevées à ce rythme, rapport complet au moins une fois par heure (à chaque tour si la limite la plus serrée n'est pas une fenêtre Claude). Le dashboard ouvert se recharge au même rythme. |
| | Thème | Système, Clair, Sombre (Système) | Système suit le clair/sombre du bureau (sous Linux, par xdg-desktop-portal). |
| | Lancer à l'ouverture de session | oui / non (non, sauf case de l'installeur Windows cochée) | Pas depuis les sources (interrupteur estompé). Windows : valeur `AgentBurn` de `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (une désactivation faite dans le Gestionnaire des tâches est respectée ; réactiver l'option l'annule). Linux : `~/.config/autostart/io.github.magikdidi24.AgentBurn.desktop`, qui lance l'exe de l'app, liens résolus (`/opt/agent-burn-desktop/agent-burn-desktop` pour les paquets), ou le fichier de l'AppImage ; `Hidden=true` ou `X-GNOME-Autostart-enabled=false` (posés par l'outil du bureau) valent désactivé ; seul ce fichier est créé ou retiré. Un chemin d'app qui contient un caractère de contrôle (saut de ligne…), `%` ou `\` est refusé et l'option reste désactivée (noté dans le journal) : l'entrée serait détournée ou ignorée. |
| | Garder dans la zone de notification à la fermeture | oui / non (oui) | Non : fermer le dashboard quitte l'app. |
| | Clic sur l'icône | Aperçu, Dashboard (Dashboard sous Wayland, Aperçu ailleurs) | Action du clic gauche. |
| Fournisseurs | — | — | Claude Code, Codex, puis chaque autre agent vu : état, explication, âge du relevé, dernière erreur propre à l'agent. CLI agent-burn : emplacement, version (« illisible » si `--version` ne répond rien, « sans réponse (10 s) » s'il bloque), état du rapport suivi de l'erreur du CLI en cas d'échec, bouton « Rafraîchir maintenant ». |
| Diagnostic | — | — | Versions (app, CLI, CLI prévu par le build), système, affichage (« Wayland (KDE) », « X11 (GNOME, session Wayland) » pour une app X11 sous Wayland…), écrans, zone de notification, dossiers. Boutons « Ouvrir les journaux », « Ouvrir le dossier des données », « Copier le diagnostic ». Interrupteur « Journal détaillé (débogage) », sans redémarrer (contenu : voir [Vie privée](#vie-privée--ce-que-lapp-lit-et-écrit)). Dernières erreurs (heure, origine, message). Bouton « Réinitialiser les paramètres », en deux temps : il devient « Confirmer la réinitialisation » pendant 5 s, et seul un 2e appui réinitialise. |
| À propos | — | — | Versions, crédit, bouton « Licences » (app installée). |

Les réglages sont dans `settings.json` (voir [Où sont les fichiers](#où-sont-les-fichiers)) : `refreshMinutes`,
`theme`, `closeToTray`, `trayClick`, `debugLogging`. Une valeur invalide reprend son défaut (noté dans le
journal). Un fichier enregistré avec une marque d'ordre des octets UTF-8 (Bloc-notes, PowerShell 5) est lu
normalement. Un fichier illisible (JSON invalide, même imbriqué à l'extrême) est copié en `settings.json.bak`, les
défauts s'appliquent et Diagnostic l'annonce. Le lancement à l'ouverture de session n'y est pas : il est lu dans
le système.

## État des données

Affiché en bas de l'aperçu et du dashboard, dans Paramètres → Fournisseurs, et dans la bulle de l'icône quand
aucune limite n'est relevée.

| État | Quand | Que faire |
|---|---|---|
| **En direct** | Le dernier rapport du CLI a réussi il y a moins d'une heure, plus un tour de rafraîchissement et 2 min (la durée maximale d'un run : le rapport horaire en cours ne fait pas passer « En cache »). | Rien. |
| **En cache** | Rapport relu sur le disque au lancement, en attendant le premier run ; ou dernier run en échec (erreur du CLI, pas de réponse en 120 s, rapport illisible, CLI absent) ; ou rapport trop vieux. Les derniers chiffres restent affichés. | Rafraîchir. Si ça dure, lire l'erreur (bas de l'aperçu, Paramètres → Diagnostic → Dernières erreurs). |
| **Indisponible** | Aucun rapport réussi, même ancien. | Attendre le premier rapport, sinon voir [Dépannage](#dépannage). |

## État de chaque fournisseur

Affiché sur l'onglet de l'agent, en tête de sa page du dashboard, dans la carte Fournisseurs, dans Paramètres →
Fournisseurs et dans le menu de l'icône quand il n'y a pas de limite. Détail des signaux dans
[docs/PROVIDERS.md](docs/PROVIDERS.md).

| Libellé | Signifie | Que faire |
|---|---|---|
| **En direct** | Limites relevées récemment : sur le compte Claude depuis moins de 10 min, ou de deux tours de rafraîchissement quand le rythme dépasse 5 min (30 min au rythme de 15 min, 60 min à 30 min) ; pour les autres agents, dans le dernier rapport, lui-même en direct. | Rien. |
| **Relevé ancien** | Dernières limites connues, gardées à l'écran : Claude n'a pas été relevé depuis plus longtemps que ce seuil (le détail le donne : « aucun relevé depuis plus de 10 min »), à cause du réseau ou de l'API d'usage qui refuse les appels trop fréquents ; pour les autres, rapport en cache. | Rafraîchir, vérifier le réseau. |
| **Connexion à vérifier** | Claude seulement : le renouvellement de la connexion a été refusé. Soit la connexion a expiré, **soit** le réseau était coupé alors que le jeton avait expiré (sortie de veille avant le Wi-Fi) : le CLI ne fait pas la différence. | Vérifier le réseau, puis Rafraîchir. Si ça persiste avec le réseau : `claude` dans un terminal, puis `/login`. |
| **Usage local** | Dépense lue dans les journaux, pas de limites. Claude : non connecté ou hors ligne (le CLI ne dit pas lequel). Autres : pas de limite dans le rapport, ou limites de plus de 7 jours (vieux journaux Codex), écartées. | Claude : se connecter, vérifier le réseau. Codex : une session Codex récente remet ses limites à jour. |
| **Non détecté** | Le CLI ne trouve ni usage ni abonnement pour cet agent. | Normal si l'agent ne sert pas sur cette machine avec ce compte. |
| **Rapport en échec** | Aucun rapport réussi, même ancien, et le dernier run du CLI a échoué : le détail est l'erreur du CLI. | Lire l'erreur, puis Rafraîchir ; voir les [erreurs du CLI](#cli-introuvable). |
| **Inconnu** | Pas encore de rapport, et pas d'échec. | Attendre quelques secondes. |
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
| Instance unique | tube nommé `\\.\pipe\AgentBurn-<utilisateur>-<session>`, verrou `%LOCALAPPDATA%\AgentBurn\cache\AgentBurn-<utilisateur>-<session>.lock` | `$XDG_RUNTIME_DIR/AgentBurn.sock` et son verrou `AgentBurn.sock.lock` |
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
  quand l'option est active, et son point d'instance unique avec son verrou. L'usage (coûts, jetons, modèles,
  forfait) y est stocké en clair.
- **Journaux** : ligne de commande de chaque run du CLI (avec les chemins), code de sortie, durée, taille de la
  sortie, la ligne `Error:` du CLI en cas d'échec ; jamais le rapport lui-même. Aussi les messages Qt et QML, les
  erreurs Python avec leur trace, et l'apparition ou la disparition de la zone de notification.
- **Journal détaillé (débogage)**, en plus : la fin du stderr de chaque run du CLI (4 000 caractères au plus), les
  réglages en vigueur au démarrage et à chaque changement, chaque écriture des réglages, le thème du système et
  ses changements, les clics sur l'icône, les 2es lancements passés à l'instance en cours.
- **Masqués** en `[masqué]`, dans le journal comme sur la sortie d'erreur : jetons `sk-ant-…`, valeurs `Bearer`,
  JWT, valeurs de jetons access/refresh/id (aussi dans un JSON échappé, tel que le CLI l'affiche dans une
  erreur), adresses e-mail, chaînes hexadécimales ou base64 de 32 caractères ou plus qui mêlent chiffres et
  lettres, y compris juste après un `=` (`CLE=valeur`, paramètre d'URL) ; les UUID de chemins le sont aussi. Ce
  sont des motifs : un secret d'une autre forme passerait.
- **Diagnostic copié** : mêmes masques, aucune variable d'environnement ni contenu de fichier. Il contient les
  chemins des dossiers, donc le nom d'utilisateur.

## Dépannage

### Pas d'icône dans la zone de notification

- Windows : l'icône est peut-être derrière la flèche **^** de la barre des tâches : l'en sortir par
  glisser-déposer.
- GNOME : installer et activer l'extension AppIndicator (déjà active sous Ubuntu). Paramètres → Général le
  signale quand aucune zone de notification n'est détectée.
- Panneau lancé, ou extension activée, après l'app : l'icône apparaît dans les 5 s, sans relancer.
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

Autres erreurs du CLI, affichées telles quelles en bas de l'aperçu et du dashboard, dans Paramètres →
Fournisseurs (« Rapport ») et dans Diagnostic → Dernières erreurs. Sans aucun rapport, même ancien, chaque
fournisseur affiche « Rapport en échec » avec le message ; sans limite connue, l'infobulle de l'icône (et sans
données, son menu) dit « échec du CLI (voir Paramètres › Diagnostic) » :

- « agent-burn a échoué (code 1) : … » suit le message du CLI. Par exemple « No valid Claude data directories
  found in CLAUDE_CONFIG_DIR » : la variable `CLAUDE_CONFIG_DIR` pointe vers un dossier sans `projects/`, ce qui
  fait échouer tout le rapport, Codex compris. La corriger ou la retirer.
- « CLI agent-burn incompatible » (code 2) : le CLI refuse une option ; il ne correspond pas à la version prévue
  par l'app (réinstaller, ou retirer `AGENT_BURN_BIN`).
- « agent-burn n'a pas répondu en 120 s » : run arrêté. Possible hors ligne avec un gros historique (calcul des
  prix sans tarifs téléchargés).
- « Rapport illisible renvoyé par agent-burn. » : sortie qui n'est pas un rapport. Joindre le diagnostic à un
  signalement.
- Version du CLI « illisible » ou « sans réponse (10 s) » (Paramètres → Fournisseurs) : `agent-burn --version`
  n'a rien écrit, ou n'a pas répondu en 10 s. Même remède que pour un CLI introuvable.

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
  détails, activer « Journal détaillé (débogage) » (fin du stderr de chaque run du CLI, réglages, clics sur
  l'icône), reproduire, puis joindre `agent-burn.log`.

### Réinitialiser les réglages

Paramètres → Diagnostic → **Réinitialiser les paramètres**, puis **Confirmer la réinitialisation** dans les 5 s
(le lancement à l'ouverture de session ne change pas). Ou supprimer `settings.json`, app fermée. Pour tout
effacer, supprimer aussi le dossier des données : l'historique est alors perdu.

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
- Lecteurs d'écran : l'app expose les textes de l'aperçu et du dashboard, un résumé en une phrase de chaque
  graphe (période, total et jour le plus cher ; quota restant et prévu au reset) et les noms des contrôles ; la
  navigation au clavier est en place. Vérifié seulement sur l'arbre d'accessibilité de Qt, jamais avec Orca ni
  Narrateur.
- Linux : rendu Qt sans fil dédié (`QSG_RENDER_LOOP=basic`), car la boucle à fil de Qt 6.12 plante parfois sous
  Wayland à l'ouverture d'une fenêtre, bien plus souvent avec les textes exposés aux lecteurs d'écran (vu en
  session KWin imbriquée, rendu logiciel). L'app anime peu, la boucle basique lui suffit. Une valeur de
  `QSG_RENDER_LOOP` déjà définie l'emporte. Pas revérifié sur un vrai GPU ni un vrai compositeur ; bug Qt non
  signalé.
- Windows : barre de titre sombre non vérifiée (Wine ne l'applique pas), sans effet attendu avant Windows 10
  20H1.
- Taille : environ 195 Mo installés sous Linux ; installeur Windows d'environ 40 Mo.
- Linux x86_64 seulement, glibc 2.35 ou plus. Windows ARM64 expérimental.
- Le CLI est arrêté s'il dépasse 120 s, et par l'installeur ; à la fermeture, l'app attend 5 s au plus la fin
  d'un run en cours avant de l'arrêter. S'il réécrivait à cet instant le jeton de Claude, Claude Code pourrait
  redemander `/login` (risque lu dans le code du CLI, jamais observé).

## Licences

- **Agent Burn (cette app)** : MIT, [LICENSE](LICENSE).
- **CLI `agent-burn`** (embarqué) : MIT, © ryoppippi et Melvynx. Les licences des crates Rust liées dans le
  binaire, texte compris, sont dans `THIRD-PARTY-NOTICES.txt`.
- **Qt 6, PySide6, Shiboken6** : LGPL-3.0, utilisés sans modification. Ce sont des bibliothèques partagées
  séparées (dossier `PySide6/` de l'app ; sous Linux, aussi les liens `lib*.so.6` à sa racine) : on peut les
  remplacer par une version modifiée compatible sans recompiler l'app (LGPL-3.0, section 4 d) 1)). Notice et
  liens vers les sources : `NOTICE-Qt-PySide6.txt` ; textes : `LGPL-3.0.txt`, `GPL-3.0.txt`.
- **Composants tiers compilés dans Qt et PySide6** (ICU sous Linux, PCRE2, HarfBuzz, libpng, FreeType et zlib
  sous Windows, données Unicode, protocoles Wayland…) : plateforme, licence SPDX, copyright et texte de chacun
  dans `QT-THIRD-PARTY.txt`. Les plugins d'images que l'app n'ouvre jamais (JPEG, TIFF, WebP, GIF, TGA, WBMP,
  ICNS) et l'OpenGL logiciel de Windows (`opengl32sw.dll`) ne sont pas livrés.
- **JetBrainsMono Nerd Font** : SIL Open Font License 1.1.
- **Python** : licence PSF, avec les bibliothèques C de sa distribution et les logiciels incorporés à CPython
  (libmpdec, HACL*, Mersenne Twister…), dans `LICENSE-Python.txt`.
- Linux : notices Debian des bibliothèques système embarquées (`licenses/debian/`).
- **AppImage** seulement : son runtime (type2-runtime) contient libfuse (LGPL-2.1, avec ses sources et la façon
  de le relier), squashfuse, zstd, zlib, mimalloc et musl : `NOTICE-AppImage-runtime.txt`.

Tous ces textes sont dans le dossier `licenses/` à côté de l'exécutable, qu'ouvre Paramètres → À propos →
Licences. Le `.deb` a en plus `/usr/share/doc/agent-burn-desktop/copyright` (licence MIT de l'app, renvoi à
`licenses/`) ; le champ License du `.rpm` est l'expression SPDX de tout le contenu.

Merci à Melvynx pour [agent-burn](https://github.com/Melvynx/agent-burn) : l'app Mac a servi de modèle, et son
CLI fait toute la lecture des journaux, le calcul des prix et le relevé des limites.
