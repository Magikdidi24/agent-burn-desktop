# Agent Burn (app de bureau)

Agent Burn affiche, sous **Windows et Linux**, la dépense de vos agents de code (Claude Code, Codex et les autres
agents que reconnaît son CLI), leurs jetons et leurs modèles, et les **limites de vos abonnements en direct**, avec
le rythme à tenir : une **icône dans la zone de notification**, un **aperçu**, un **dashboard** et une fenêtre
**Paramètres**. C'est une recréation pour Windows et Linux de l'app macOS
[agent-burn](https://github.com/Melvynx/agent-burn) de Melvynx, dont elle embarque le CLI (Rust, révision
épinglée dans [`cli.env`](cli.env)) pour lire les journaux, calculer les prix et relever les limites. Licence MIT.

Documentation : [guide d'utilisation](docs/USAGE.md) (icône, aperçu, dashboard, réglages, états, fichiers, vie
privée, dépannage, désinstallation) ; pour les développeurs : [architecture](docs/ARCHITECTURE.md),
[fournisseurs](docs/PROVIDERS.md), [suivi de l'amont](docs/UPSTREAM.md),
[tests, build et release](docs/DEVELOPMENT.md).

## Plateformes

| Plateforme | Formats | Ce qui a réellement été vérifié |
|---|---|---|
| Windows 10 (1809 ou plus) et 11, x64 | installeur, zip portable | Par la CI GitHub, sur le runner `windows-2025` (Windows Server 2025) : tests unitaires ; build (CLI compilé avec MSVC, bundle, selftest de l'app gelée) ; installation silencieuse, raccourcis et registre, selftest de l'app installée, icône pendant 10 s, 2e lancement, désinstallation app lancée, zip portable ([`windows/smoke.ps1`](windows/smoke.ps1)). **Jamais sur un Windows 10 ou 11 de bureau** : SmartScreen, vraie zone de notification et barre de titre sombre jamais vus. Avant la CI : sous Wine. |
| Windows 11 ARM64 | installeur `arm64` expérimental, ou l'installeur x64 en émulation | Installeur arm64 compilé sous Wine pendant le développement ; la CI ne le construit qu'au lancement manuel (case `arm64`), jamais fait à ce jour. Jamais lancé sur une machine ARM, émulation x64 non essayée. |
| Ubuntu 22.04 et 24.04, Debian 12 et 13 | `.deb` | Paquets construits par la CI (conteneur Debian 12), puis dans un conteneur de chaque distro, sans session de bureau : installation sans les paquets recommandés, commande, lanceur, icônes, AppStream, CLI embarqué, selftest de l'app installée (rendu logiciel, puis OpenGL Mesa sous Xvfb), désinstallation complète ([`linux/smoke.sh`](linux/smoke.sh)). |
| Fedora 44 | `.rpm` (dnf) | Comme ci-dessus. |
| openSUSE Tumbleweed | `.rpm` (zypper) | Comme ci-dessus. |
| Arch Linux | archive `.tar.gz`, AppImage | Comme ci-dessus (archive installée dans `/opt`, AppImage lancée sans FUSE). |
| Autre distro x86_64 avec glibc 2.35 ou plus | AppImage, archive | Non essayé. |
| KDE Plasma (Wayland, et X11 par Xwayland) | — | En local, dans une session KWin imbriquée sans écran, sous Wayland et sous Xwayland, avec un hôte de zone de notification de test. App gelée (archive) : icône, clic, menu (Paramètres…, Journaux, Quitter), aperçu placé sous X11 ; sans hôte, dashboard puis sortie à sa fermeture. Depuis les sources : hôte apparu 130 s après l'app, hôte disparu, Quitter pendant un run du CLI. Jamais avec la vraie zone de notification de Plasma. |
| GNOME | — | GNOME 50 sans écran (conteneur), pendant l'audit, avec l'ancienne version de l'app : pas de zone de notification sans l'extension AppIndicator, une avec. L'app actuelle n'y a pas tourné. |
| XFCE, Cinnamon, Hyprland, autres | — | Non essayé. |
| EL9 (AlmaLinux, Rocky…) et toute glibc antérieure à 2.35 | — | Non pris en charge. |

La CI ([`ci.yml`](.github/workflows/ci.yml)) rejoue les vérifications Windows et Linux ci-dessus à chaque push
(résultats : onglet Actions) ; son premier run complet, vert, date du 2026-10-25, juste avant que l'app ait son
propre dépôt. S'y ajoutent, en local sous Linux et depuis les sources : tests unitaires (116), suite du cœur sous
Quickshell 0.3.2 et sous l'app (274 contrôles, 27 avec des fichiers corrompus, 6 avec un CLI bloqué), selftests,
et les sessions KWin imbriquées du tableau.

## Installer

### Où trouver les fichiers

- **[Releases](https://github.com/Magikdidi24/agent-burn-desktop/releases)** : la CI construit tous les paquets
  pour chaque tag `desktop-v<version>` et en fait une release brouillon, publiée à la main. Aucune n'est publiée
  à ce jour.
- **En attendant la première release, les artefacts de la CI** : onglet
  [Actions](https://github.com/Magikdidi24/agent-burn-desktop/actions) → workflow « Agent Burn (bureau) » → un
  run réussi → `agent-burn-desktop-linux` ou `agent-burn-desktop-windows-x64`. Il faut être connecté à GitHub
  pour les télécharger, et ils ne sont gardés qu'un jour.
- **Build local** : voir [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

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

Python 3.12 ou plus récent (les paquets Linux embarquent 3.12, ceux de Windows 3.13) et PySide6 6.12 : voir
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

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

La suite (icône, aperçu, dashboard, réglages, dépannage, désinstallation) : [docs/USAGE.md](docs/USAGE.md).

## Limites connues

- Jamais lancée sur un Windows 10 ou 11 de bureau : seulement sur le Windows Server des runners de la CI (voir
  [Plateformes](#plateformes)).
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
  `QSG_RENDER_LOOP` déjà définie l'emporte ; la nôtre ne passe ni au CLI ni à `xdg-open`. Pas revérifié sur un vrai GPU ni un vrai compositeur ; bug Qt non
  signalé.
- Windows : barre de titre sombre non vérifiée (Wine ne l'applique pas), sans effet attendu avant Windows 10
  20H1.
- Taille : environ 195 Mo installés sous Linux ; installeur Windows d'environ 40 Mo.
- Linux x86_64 seulement, glibc 2.35 ou plus. Windows ARM64 expérimental.
- Le CLI est arrêté s'il dépasse 120 s, et par l'installeur ; à la fermeture, l'app attend 5 s au plus la fin
  d'un run en cours avant de l'arrêter. S'il réécrivait à cet instant le jeton de Claude, Claude Code pourrait
  redemander `/login` (risque lu dans le code du CLI, jamais observé).

## Développement

- `app/` : l'app PySide6 (couche de compatibilité Quickshell, fenêtres, icône, réglages), ses QML et ses tests ;
  `shared/` : le cœur `Burn.qml` et les vues partagées (aperçu, dashboard, graphes) ; `linux/`, `windows/`,
  `build.ps1`, `installer.iss`, `agentburn.spec` : builds et tests des paquets ; `scripts/` : suivi du projet
  amont ; `tests/fixtures/` : sorties réelles du CLI, nettoyées ; [`cli.env`](cli.env) : révision épinglée du CLI.
- `shared/` est aussi le cœur de la barre Quickshell (Hyprland) de l'auteur, qui en garde une copie synchronisée
  depuis ce dépôt, à une révision épinglée, par un script. Ces fichiers doivent donc tourner tels quels sous
  Quickshell et sous l'app : voir [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#contrat-plateforme).
- Mise en place, tests, build et release : [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

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
