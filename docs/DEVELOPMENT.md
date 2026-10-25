# Développement, tests, build et release

Architecture : [ARCHITECTURE.md](ARCHITECTURE.md). Utilisation : [README](../README.md) et [USAGE.md](USAGE.md).

## Mise en place

- **Python 3.12** sous Linux, **3.13** sous Windows (ceux de la CI et des builds : python.org ne publie plus de
  binaires Windows de 3.12), et la seule dépendance, épinglée dans
  [`app/requirements.txt`](../app/requirements.txt) (`PySide6-Essentials==6.12.0`) :

  ```sh
  python3.12 -m venv ~/.venvs/agent-burn
  ~/.venvs/agent-burn/bin/pip install -r app/requirements.txt
  ```

  Windows : `py -3.13 -m venv .venv`, puis `.venv\Scripts\pip install -r app\requirements.txt`.

  Builds et CI installent à la place [`app/requirements.lock`](../app/requirements.lock) avec
  `pip install --require-hashes` : le verrou de [`app/requirements-build.txt`](../app/requirements-build.txt)
  (`requirements.txt` plus `pyinstaller==6.22.3`), versions et sha256 de tout l'arbre pour Linux x86_64 et
  Windows x64 et ARM64. Après un changement de l'un de ces deux fichiers, le régénérer depuis `app/` :
  `uv pip compile --universal --python-version 3.12 --generate-hashes requirements-build.txt -o requirements.lock`
  (avec `--universal`, `--python-version` est un minimum : le verrou vaut aussi pour 3.13).
- **CLI `agent-burn`**, à la révision `AB_REV` de [`cli.env`](../cli.env) :
  - Linux : `cargo install --locked --git https://github.com/Melvynx/agent-burn --rev <AB_REV> agent-burn --bin agent-burn --root ~/.local`
    (dans `~/.local/bin/agent-burn`) ;
  - Windows : un premier `build.ps1` le compile dans `build\cli\bin\agent-burn.exe` ;
  - ou pas de CLI du tout, avec les fixtures (voir plus bas).
- **Police** : les scripts de build déposent JetBrainsMono Nerd Font dans `app/fonts/`, que les lancements depuis
  les sources chargent aussi. Sans elle, il faut la police installée sur le système, sinon les icônes
  s'affichent en carrés.
- **Paquets** : podman (build et tests Linux) ; PowerShell 7.4+, Git, Rust (rustup, chaîne MSVC) et Inno Setup
  6.3+ (Windows).

## Lancer depuis les sources

Linux, depuis `app/` :

```sh
python -m agentburn                    # icône de notification, comme l'app installée
python -m agentburn --show dashboard   # cette fenêtre seule, sans icône (ou --show popover)

# Sans vrai CLI : le faux agent-burn sert les fixtures (dates décalées à aujourd'hui), données à part
AGENT_BURN_FAKE_DIR=$PWD/../tests/fixtures AGENT_BURN_BIN=$PWD/tests/fake-agent-burn \
    AGENT_BURN_DATA=/tmp/agent-burn-dev python -m agentburn --show dashboard
```

`tests/fake-agent-burn` relance `python3 -m agentburn`, qui sert les fixtures sans charger Qt : le Python du
système suffit. `tests/fixtures/codex` ajoute Codex.

Windows (PowerShell), depuis `app\` :

```powershell
$env:AGENT_BURN_BIN = "$PWD\..\build\cli\bin\agent-burn.exe"
python -m agentburn
```

Différences avec l'app installée :

- mêmes dossiers de données et de réglages que l'app installée : `AGENT_BURN_DATA` en donne un autre. L'ancien
  dossier de dev `~/.local/share/agent-burn-win-dev` n'est pas repris ;
- pas de lancement à l'ouverture de session (aucun exe installé à lancer) ;
- journal aussi sur la sortie d'erreur ; Diagnostic affiche « version de développement » et le CLI prévu par
  `cli.env` ;
- les QML partagés sont relus dans `shared/` à chaque lancement (copie préparée dans le cache) : une
  modification est prise au lancement suivant ;
- `AGENT_BURN_FAKE_DIR` hors selftest est signalé dans le journal.

## Tests

Sous Linux, cette fonction (bash ou zsh) garde les tests hors de la session graphique et du bus D-Bus de
l'utilisateur :

```sh
t() { env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen PYTHONDONTWRITEBYTECODE=1 dbus-run-session -- "$@"; }
```

| Quoi | Commande | Dans la CI |
|---|---|---|
| Tests unitaires | `t python -m unittest discover -s tests -v` (depuis `app/`) | Linux et Windows |
| Suite du cœur sous le shim | `t python tests/run_burn_suite.py`, puis avec `BURN_TEST=corrupt` et `BURN_TEST=timeout` | Linux |
| Suite du cœur sous Quickshell | voir plus bas | non |
| Suivi de l'amont | `python3 -I scripts/test_agent_burn_upstream.py` (depuis la racine) | Linux ; le contrôle qui demande le vrai CLI (`~/.local/bin/agent-burn`, sauté sans lui) tourne dans le job des paquets, avec le CLI qu'il vient de construire |
| Outils de licence (notices des crates, licence du `.rpm`) | `python3 -m unittest discover -s .` (depuis `tools/`) | Linux |
| Selftest | voir plus bas | Linux (Xvfb), et sur chaque build gelé |
| Paquets Linux | `linux/smoke-local.sh IMAGE` | 7 distros |
| Installeur Windows | `windows/smoke.ps1` | Windows x64 |

### Tests unitaires

Faux CLI, démarrage (boucle de rendu, instance unique et son verrou, taille des fenêtres sur petit écran,
fermeture avec ou sans zone de notification), aperçu (défilement au clavier), icône et menu (zone de notification
apparue ou disparue), copie QML en cache, réglages (BOM, JSON très imbriqué) et fenêtre Paramètres (Entrée,
flèches, focus visible, contraste, réinitialisation en deux temps), journal et masquage, diagnostic, dossiers,
démarrage automatique Linux et Windows (registre factice), shim (environnement, stderr, dossier courant, journal,
attente des runs à la fermeture), contrôle des captures du selftest. Ils posent eux-mêmes
`QT_QPA_PLATFORM=offscreen` et `QT_QUICK_BACKEND=software` ; sous Windows, `python -m unittest discover -s tests -v`
suffit (6 tests propres à Linux y sont sautés).

### Suite du cœur (Burn.qml)

[`app/tests/burn-suite/shell.qml`](../app/tests/burn-suite/shell.qml) teste `Burn.qml` sans fenêtre, avec un faux
CLI (`burn-suite/fake/`) qui rejoue les fixtures et des pannes (code 1 ou 2, JSON illisible, CLI bloqué, relevé
léger). Elle doit donner le même résultat sous le shim et sous Quickshell : c'est la preuve de fidélité du shim.
Résultat attendu : `RESULT: N ok, 0 échec(s)`, avec aujourd'hui N = 274 (normal), 27 (`corrupt`) et 6
(`timeout`) : un N plus petit veut dire que des étapes n'ont pas tourné.

Sous le shim, depuis `app/` (code 1 si un test échoue) :

```sh
t python tests/run_burn_suite.py
t env BURN_TEST=corrupt python tests/run_burn_suite.py   # fichiers persistés illisibles
t env BURN_TEST=timeout python tests/run_burn_suite.py   # CLI bloqué, délai abaissé à 10 s : environ 20 s
t python tests/run_burn_suite.py <dossier>   # autre shell.qml ; son Burn.qml remplace celui du dépôt (mutants)
```

Sous Quickshell 0.3.2, depuis `app/`, sur une copie (qs travaille hors du dépôt, et ses
dossiers XDG jetables laissent les données de la vraie barre intactes) :

```sh
S=$PWD/tests/burn-suite
R=$(mktemp -d /tmp/abq.XXXX)   # chemin court : le socket IPC de qs ($R/quickshell/by-id/<id>/ipc.sock) a 108 octets au plus
mkdir -p $R/suite $R/fake $R/data $R/state $R/cache $R/config
cp $S/shell.qml ../shared/Burn.qml $R/suite/   # Burn.qml de shared/, pas le lien de burn-suite
python3 -I $S/fake/gen.py $R/fake
env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen XDG_RUNTIME_DIR=$R XDG_DATA_HOME=$R/data \
    XDG_STATE_HOME=$R/state XDG_CACHE_HOME=$R/cache XDG_CONFIG_HOME=$R/config AGENT_BURN_BIN=$R/fake/agent-burn \
    dbus-run-session -- timeout 60 qs -p $R/suite 2>&1 | grep -a 'RESULT\|FAIL'
```

qs sort en 0 même quand des tests échouent : lire la ligne `RESULT`. Mêmes variantes avec `BURN_TEST=corrupt`
et `BURN_TEST=timeout`. Les avertissements de qs sur Wayland, l'inactivité ou les portails
viennent de l'environnement sans écran.

La suite ne tourne que sous Linux : sous Windows, la console en cp1252 abîme ses messages (vu sous Wine).

### Selftest

`python -m agentburn --selftest DIR` rend l'icône (16, 24, 32 px), l'aperçu (onglets Claude et Général), le
dashboard (Tous les agents, Claude) et les 4 sections des réglages, avec les onglets et la page Codex si les
fixtures en ont. Il écrit les PNG, `agent-burn.log` et `selftest.json`
(`ok`, `qmlErrors`, `warnings`, `captureErrors`, `dataLoaded`, `cliError`), et sort en 0 seulement si tout est
propre : données chargées, aucun avertissement QML, aucune erreur du CLI, aucune capture vide, d'une seule
couleur ou de mauvaise taille. Il ne voit pas une police d'icônes manquante : regarder les PNG.

Il lui faut OpenGL (le rendu logiciel ignore masques et ombres) : sous Xvfb comme la CI, dans une session de
bureau (rendu hors écran) ou dans une session imbriquée.

```sh
cd app
AGENT_BURN_FAKE_DIR=$PWD/../tests/fixtures AGENT_BURN_BIN=$PWD/tests/fake-agent-burn AGENT_BURN_DATA=/tmp/ab-selftest-data \
    xvfb-run -a -s '-screen 0 1920x1080x24' dbus-run-session -- python -m agentburn --selftest /tmp/ab-shots
```

Sans OpenGL : `QT_QUICK_BACKEND=software` (passe, sans ombres ni masque du logo). Avec Codex :
`AGENT_BURN_FAKE_DIR=$PWD/../tests/fixtures/codex`. Les builds lancent le même selftest sur l'app gelée, l'exe
servant lui-même de faux CLI (`AGENT_BURN_BIN` = l'exe).

Hors écran (`QT_QPA_PLATFORM=offscreen`, défaut du selftest sous Linux), l'app garde la boucle de rendu à fil de
Qt : la boucle basique, celle de l'app sous Linux, y perd le haut de la carte de l'aperçu dans la capture. Sous
xcb (`QT_QPA_PLATFORM=xcb`, le selftest OpenGL des builds) ou Wayland, elle prend la basique comme l'app.

### Paquets Linux en conteneur

Après un build (voir plus bas), pour chaque image :

```sh
linux/smoke-local.sh docker.io/library/debian:13   # DIST = dist/linux par défaut
```

Images de la CI : `ubuntu:22.04`, `ubuntu:24.04`, `debian:12`, `debian:13`, `fedora:44`,
`archlinux:latest`, `opensuse/tumbleweed` (en local : `docker.io/library/…`,
`registry.fedoraproject.org/fedora:44`, `registry.opensuse.org/opensuse/tumbleweed:latest`).
[`linux/smoke.sh`](../linux/smoke.sh) vérifie `SHA256SUMS`, installe le paquet natif sans ses recommandations
(Arch : l'archive dans `/opt` et `/usr/local`), contrôle le `PATH`, le lanceur, les icônes, AppStream, le fichier
`/usr/share/doc/agent-burn-desktop/copyright` (Debian, Ubuntu) et `--version` du CLI embarqué, résout chaque
bibliothèque du bundle avec `ldd` (`find` installé sous openSUSE, dont l'image ne l'a pas ; échec sans lui),
lance le selftest de l'app installée (rendu logiciel, puis OpenGL Mesa sous Xvfb), désinstalle et vérifie qu'il
ne reste aucun fichier. Sous Arch, il essaie aussi l'AppImage (`APPIMAGE_EXTRACT_AND_RUN=1`). Journaux et captures : `dist/linux/smoke-<distro>-<version>/` (dans la CI,
artefact `smoke-<n>` en cas d'échec).

### Installeur Windows : `smoke.ps1`

```powershell
pwsh -File windows\smoke.ps1 -Setup <...\AgentBurn-Setup-<ver>-x64.exe> -Portable <...\AgentBurn-portable-<ver>-x64.zip>
```

Il exige une machine **sans** Agent Burn (installation, process, démarrage automatique ou `%APPDATA%\AgentBurn`)
et refuse sinon : il installe puis désinstalle pour de bon. Fait pour les runners de la CI ou une machine
virtuelle jetable. Contrôles : installation silencieuse (fichiers, raccourcis, valeur `Run`, clé de
désinstallation), selftest de l'exe installé, mode icône pendant 10 s, 2e lancement qui rend la main en 0,
désinstallation app lancée (dossier, raccourcis, valeurs `Run` et `StartupApproved`, cache et journaux partis,
`%APPDATA%\AgentBurn` gardé), puis selftest du zip portable. Sorties dans `dist/smoke/` (dans la CI, artefact
`selftest-windows-<arch>`, sans la copie extraite du zip). Il tourne dans la CI, sur le runner `windows-2025`
(Windows Server 2025), jamais sur un Windows de bureau ; avant la CI, sa logique avait été rejouée en Python sous Wine
(43 contrôles sur 43, avec en plus une mise à jour par-dessus une ancienne installation et le refus de
l'installeur arm64 sur x64).

### Sous Wine

Utile pour dégrossir, pas une vérification Windows (le labo Wine du développement n'est pas dans le dépôt) :

- fonctionnent : Python 3.12 Windows avec PySide6 6.12 (tests unitaires), PyInstaller, ISCC, l'installeur
  (installation, mise à jour, désinstallation) et le selftest de l'app gelée ;
- Wine ne transmet pas les variables Unix `QT_*` : les poser côté Windows (`cmd /c "set QT_QPA_PLATFORM=offscreen&& …"`) ;
- PowerShell 7 ne tourne pas sous Wine : `build.ps1` et `smoke.ps1` ne peuvent pas y être essayés ;
- pas de chaîne MSVC : le CLI du labo était compilé en croisé (`x86_64-pc-windows-gnu`), pas celui des builds ;
- Wine n'applique pas la barre de titre sombre et ne dit rien de SmartScreen, de Defender ni de la vraie zone
  de notification.

## Construire

### Linux : `linux/build-local.sh`

```sh
linux/build-local.sh                       # podman, image python:3.12-slim-bookworm, réseau
SKIP_CLI=1 linux/build-local.sh            # réutilise le CLI de build/cli-linux tel quel
AB_CACHE=/chemin/absolu linux/build-local.sh   # caches cargo, rustup, pip dans ce dossier
```

Le wrapper lance [`linux/build.sh`](../linux/build.sh) dans le conteneur, en root, dépôt monté. L'image est
épinglée par son empreinte, la même que dans la CI (`--pull=missing` : téléchargée une fois) ; pour la monter,
changer l'empreinte aux deux endroits. Les caches cargo, rustup et pip vont dans `AB_CACHE` (par défaut le volume
podman `agent-burn-build-cache`). Le wrapper passe aussi le commit du dépôt (`GITHUB_SHA`), que `build-info.json`
enregistre : depuis un worktree, le `.git` monté pointe hors du conteneur et `build.sh` ne le lirait pas.
`build.sh` refuse de tourner ailleurs que dans Debian 12 : le bundle prend la glibc de bookworm (plancher 2.35)
et tourne donc sur les distros plus récentes. Sans `CARGO_HOME` ni `RUSTUP_HOME`, il prend `$HOME/.cargo` et
`$HOME/.rustup` (dans la CI, le registre de `$HOME/.cargo` est en cache avec le CLI).

Étapes :

1. lit `AB_REV`, `AB_VER` (`cli.env`) et `__version__` (`app/agentburn/__init__.py`) ;
2. CLI (seulement s'il est à compiler : gcc et musl ne sont installés qu'alors) : copie superficielle de l'amont
   à `AB_REV`, Rust de son `rust-toolchain.toml` (rustup-init épinglé),
   binaire statique `x86_64-unknown-linux-musl` (repli `gnu` si l'amont casse ce build), `--version` == `AB_VER`,
   licence et notices des crates ; en cache dans `build/cli-linux/` (clé : `AB_REV`) ;
3. polices JetBrainsMono Nerd Font v3.4.0 vérifiées par sha256 ;
4. venv depuis `app/requirements.lock` (versions et sha256, `--require-hashes`), recréé quand il change ;
5. icônes, `licenses/` (dont `QT-THIRD-PARTY.txt` et `LICENSE-Python.txt` complété des logiciels incorporés à
   CPython), `build-info.json`, puis le bundle PyInstaller ([`agentburn.spec`](../agentburn.spec), sans les
   plugins d'images inutilisés) ; arrêt si Qt, PySide6 ou Python ne sont plus ceux que décrivent les notices (voir
   [Monter Qt, PySide6, Python ou le runtime AppImage](#monter-qt-pyside6-python-ou-le-runtime-appimage)) ;
6. refus d'un bundle qui demande une bibliothèque ni embarquée ni déclarée dans [`linux/nfpm.yaml`](../linux/nfpm.yaml) ;
   calcul de la glibc minimale ;
7. selftests de l'app gelée : rendu logiciel, puis OpenGL sous Xvfb ;
8. `.deb` (avec `/usr/share/doc/agent-burn-desktop/copyright`) et `.rpm` (champ License : l'expression SPDX de
   tout le contenu, calculée par [`tools/package_license.py`](../tools/package_license.py) d'après les notices),
   archive, AppImage (appimagetool et runtime épinglés ; `NOTICE-AppImage-runtime.txt` dans l'AppImage
   seulement), `SHA256SUMS`.

Sorties dans `dist/linux/` : `agent-burn-desktop-<ver>-x86_64.tar.gz`, `…-x86_64.AppImage`,
`agent-burn-desktop_<ver>_amd64.deb`, `agent-burn-desktop-<ver>-1.x86_64.rpm`, `SHA256SUMS`,
`selftest/{software,opengl}/`. Temps relevés sur le poste de développement : environ 3 min à froid, dont 80 s de
CLI, 1 min 30 avec le CLI en cache. `build/`, `dist/` et `app/fonts/` sont ignorés par git.

### Windows : `build.ps1`

Windows 10/11 avec PowerShell 7.4+ (`winget install Microsoft.PowerShell`), Python 3.13 de la même
architecture que la cible dans le `PATH`, Git, Rust via [rustup](https://rustup.rs) (chaîne MSVC, Build Tools
C++ de Visual Studio) et [Inno Setup](https://jrsoftware.org/isdl.php) 6.3+ (`iscc` dans le `PATH`, ou son
dossier par défaut). Réseau : GitHub, crates.io, PyPI.

```powershell
pwsh -File build.ps1               # x64 : CLI, polices, licences, bundle, selftest, zip, installeur
pwsh -File build.ps1 -Arch arm64   # sur une machine ARM64, avec un Python ARM64
pwsh -File build.ps1 -SkipCli      # réutilise build\cli tel quel (itérations sans Rust)
```

- `-Arch` (`x64` par défaut, en minuscules) choisit la cible Rust ; le Python du venv doit être de la même
  architecture (PyInstaller gèle le sien), sinon le script s'arrête : supprimer `.venv` et relancer. Le venv est
  rempli depuis `app/requirements.lock` (`--require-hashes`).
- Le CLI est compilé depuis une copie superficielle de l'amont à `AB_REV`, dans `%TEMP%\agent-burn-cli` (effacé
  après), en CRT statique ; le témoin `build\cli\rev` (`<AB_REV> <cible>`) évite de le recompiler.
- Avant PyInstaller : `build\bundle-extra\licenses\` (dont `QT-THIRD-PARTY.txt`, et `LICENSE-Python.txt`
  complété des logiciels incorporés à CPython, absents du `LICENSE.txt` de python.org), `build-info.json` et la
  ressource de version de l'exe ; arrêt si les notices ne décrivent pas les Qt, PySide6 et Python du venv ; après
  PyInstaller : le build échoue si l'un d'eux manque au bundle.
- Le selftest de l'app gelée tourne quelques secondes avant le zip et l'installeur : ne pas cliquer dessus.
  Il échoue sur la moindre erreur ou capture ratée (voir `dist\selftest\selftest.json` et `stderr.txt`, en
  UTF-8 comme le journal).
- Relançable : venv, polices et CLI déjà faits sont réutilisés ; bundle, zip et installeur sont écrasés.
- Le journal marque chaque étape avec le temps écoulé (`== [Ns] …`, comme `build.sh`) ; d'Inno Setup, il garde
  la version du compilateur, ses avertissements et la durée de compilation.

Sorties dans `dist\` : `AgentBurn\` (bundle), `AgentBurn-portable-<ver>-<arch>.zip`,
`AgentBurn-Setup-<ver>-<arch>.exe`, `selftest\`. [`installer.iss`](../installer.iss) ne se compile que par
`build.ps1` (`/DAppVersion` et `/DArch` obligatoires). Ses lignes `[InstallDelete]` vident les sous-dossiers du
bundle (fichiers d'une version précédente) seulement par-dessus une installation d'Agent Burn (`OwnInstall` :
`AgentBurn.exe` et `unins000.dat` présents dans `{app}`), et le choix du dossier est désactivé
(`DisableDirPage`) : un dossier existant pris à la main serait vidé à la mise à jour suivante. `build.ps1` ne
tourne pas sous Wine (pas de PowerShell 7) : il n'a tourné que dans la CI, sur le runner `windows-2025`.

### Monter Qt, PySide6, Python ou le runtime AppImage

Les notices de [`tools/licenses/`](../tools/licenses/) décrivent des versions précises, données par leur première
ligne : `QT-THIRD-PARTY.txt` (Qt et PySide6), `PYTHON-<X.Y>-THIRD-PARTY.txt` (une par version mineure de
Python livrée : 3.12 sous Linux, 3.13 sous Windows), `NOTICE-AppImage-runtime.txt` (`RUNTIME` de `build.sh`).
`build.sh` et `build.ps1` s'arrêtent tant qu'elles ne correspondent plus (ou que la notice de leur Python
manque). Après un changement de PySide6 (donc de Qt) ou de Python, régénérer le verrou (voir
[Mise en place](#mise-en-place)), puis refaire la notice concernée ; après un changement de `RUNTIME`, refaire
celle du runtime. Les scripts qui les ont produites ne sont pas dans le dépôt. Sources utilisées : les
`qt_attribution.json` et les fichiers de licence de qtbase, qtdeclarative, qtwayland et pyside-setup à l'étiquette
de la version, choisis d'après les bibliothèques vraiment livrées ; la section « Licenses and Acknowledgements for
Incorporated Software » de `Doc/license.rst` de CPython, plus la notice de HACL* ; les sources de type2-runtime et
des bibliothèques qu'il lie.

## Release

1. Monter `__version__` dans [`app/agentburn/__init__.py`](../app/agentburn/__init__.py), au format `X.Y.Z`
   (chiffres seulement : ressources de version Windows).
2. Commit, push, et attendre un run vert de la CI sur ce commit.
3. Tag : `git tag desktop-v<ver> && git push origin desktop-v<ver>`.
4. La CI refait tout, CLI compris : sur un tag, il est toujours compilé depuis les sources de l'amont, jamais
   repris du cache. Puis le job « Release (brouillon) » crée une release **brouillon** « Agent Burn <ver> (app
   de bureau) » : paquets Linux (AppImage, `.deb`, `.rpm`, archive), installeur et zip Windows x64, un
   `SHA256SUMS`. ARM64 n'y est jamais. Il refuse un tag `desktop-vX.Y.Z` dont le `.deb` et l'installeur x64 ne
   sont pas en version X.Y.Z (`__version__` différente) : erreur, aucune release.
5. Avant de publier, à la main :
   - `sha256sum -c --ignore-missing SHA256SUMS` sur les fichiers téléchargés ;
   - installer sur un vrai Windows : SmartScreen, icône, aperçu contre l'icône, Paramètres → Diagnostic (versions
     de l'app, du CLI, du CLI prévu) ;
   - installer un paquet sur un vrai bureau Linux (KDE, ou GNOME avec AppIndicator) ;
   - notes : changements, version du CLI (`AB_VER`), limites connues ;
   - publier le brouillon.
6. Pour refaire une release : supprimer d'abord le brouillon (`gh release delete desktop-v<ver>`), puis relancer
   le run du tag.

La date de release des métadonnées AppStream est le jour du build.

## CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml), « Agent Burn (bureau) ». Premier run complet le
2026-10-25, juste avant que l'app ait son propre dépôt : tous les jobs verts (la release, sans tag, sautée), ARM64
jamais lancé. Le fichier passe actionlint (avec shellcheck) sans erreur.

Déclencheurs : push sur toute branche, sauf quand il ne touche que des `*.md` ou `docs/` ; pull request, même
règle ; tag `desktop-v*` (GitHub n'applique pas les filtres de chemins aux tags : tout tourne, release comprise) ;
lancement manuel avec une case `arm64` (bouton « Run workflow » de l'onglet Actions, ou
`gh workflow run ci.yml --ref <branche> -f arm64=true`). Un nouveau push annule le run en cours de la même
branche, du même tag ou de la même pull request ; un push et la pull request de sa branche tournent chacun.

| Job | Machine | Contenu | Artefacts |
|---|---|---|---|
| Tests | `ubuntu-24.04` | bibliothèques Qt, Xvfb et Mesa ; dépendances du verrou haché ; tests unitaires ; outils de licence (`tools/`) ; suite du cœur (normal, corrompu, CLI bloqué) ; suivi de l'amont ; selftest sous Xvfb | `selftest-linux-dev` (7 jours) |
| Linux (paquets) | conteneur `python:3.12-slim-bookworm`, épinglé par empreinte | `linux/build.sh`, puis le contrôle du suivi amont avec le CLI construit | `agent-burn-desktop-linux` (30 jours) |
| Paquets sur … | 7 conteneurs de distros (étiquettes, pas d'empreinte : des distros à jour) | `linux/smoke.sh` sur l'artefact téléchargé dans `dist-in/` | `smoke-<n>` en cas d'échec (7 jours) : journaux et captures de `smoke.sh` |
| Windows x64 | `windows-2025` (image épinglée : `windows-latest` en changerait sans prévenir) | Python 3.13 ; venv `.venv` rempli du verrou haché (celui de `build.ps1`), tests unitaires sur un vrai Windows (sortie en UTF-8, 5 min au plus), Inno Setup (choco 6.7.1 si absent), `build.ps1`, `smoke.ps1` | `agent-burn-desktop-windows-x64` (30 jours, déposé avant `smoke.ps1`), `selftest-windows-x64` (7 jours, dès que le build a tourné : selftest du build et sorties de `smoke.ps1`, sans la copie extraite du zip) |
| Windows ARM64 (expérimental) | `windows-11-arm` | comme x64 ; seulement au lancement manuel avec `arm64`, son échec n'échoue pas le run | idem, `-arm64` |
| Release (brouillon) | `ubuntu-24.04` | tags `desktop-v*` seulement, après les paquets et Windows : refus d'un tag dont la version n'est pas celle des paquets, `SHA256SUMS`, `gh release create --draft --verify-tag` | release brouillon |

- Caches : CLI par `AB_REV` (et par architecture sous Windows) avec le registre cargo, sauvé dès la compilation
  même si la suite échoue, jamais repris par un tag de release ; polices extraites (`app/fonts`, revérifiées
  par sha256 à chaque build) ; pip des jobs Tests et Windows (setup-python), indexé par le verrou. Pas de cache
  de la chaîne Rust : rustup installe celle de l'amont à chaque compilation du CLI (15 s environ), et un cache
  par révision ne serait jamais relu. Un cache n'est vu que de sa branche et de `main` : fusionner le workflow
  dans `main` les amorce pour toutes les branches.
- Hygiène : actions épinglées par SHA (version en commentaire), `persist-credentials: false`, permissions
  `contents: read` (sauf la release), délai maximal sur chaque job, `pull_request` et jamais
  `pull_request_target` (une pull request de fork n'a ni secret ni droit d'écriture), runs groupés par numéro de
  pull request ou par ref complet (celle d'un fork ne peut pas annuler un run du dépôt).
- `build-info.json` du build Linux : sur une pull request, le commit de tête de la PR (`PR_HEAD_SHA`), pas le
  commit de fusion temporaire que la CI construit.
- Pas dans la CI : la suite du cœur sous Quickshell, la suite du cœur sous Windows, un lint QML.
- Durées du premier run complet : tests 3 min 40 (dont 2 min pour la suite « CLI bloqué », 20 s depuis),
  paquets Linux 2 min 30, Windows x64 10 min, chaque distro 1 min environ, soit 15 min de bout en bout ; plus 5 à
  12 min quand le CLI est recompilé (estimation). Dépôt public : GitHub ne facture pas les minutes de ses runners
  standard. Les artefacts de paquets (environ 300 Mo Linux et 110 Mo Windows par run) sont gardés 30 jours,
  déposés sans recompression (`compression-level: 0`) : en attendant la première release, c'est là que les
  utilisateurs les trouvent (voir le README).

## Conventions

- **Langue** : commentaires du code, textes de l'interface et docs en français ; messages de commit en anglais,
  au format Conventional Commits (`feat(desktop): …`, `fix(burn): …`, `build: …`, `ci: …`, `test: …`, `docs: …`).
- **QML partagé** (`shared/`) : doit tourner tel quel sous Quickshell 0.3.2 (la barre Quickshell de l'auteur en
  garde une copie synchronisée depuis ce dépôt) et sous PySide6 6.12 par le shim. Seulement les symboles du [contrat plateforme](ARCHITECTURE.md#contrat-plateforme),
  pas de `QtQuick.Controls`. Un fichier partagé de plus va dans `runtime.SHARED` (lu aussi par
  `agentburn.spec`), sinon « X is not a type ». Vérifier sous les deux hôtes : suite du cœur, selftest, et un
  rendu sous qs.
- **Lecteurs d'écran, QML partagé** : un nouveau `Txt` qui sert de libellé à un `BurnButton` ou à un champ, ou qui
  a son propre `Accessible.name`, prend `spoken: false`, sinon il est annoncé deux fois quand
  `Burn.accessibleText` est vrai (voir [le contrat plateforme](ARCHITECTURE.md#contrat-plateforme)).
- **Glyphes Nerd Font** (zone à usage privé Unicode) : dans les QML et le Python, toujours en échappement
  `\uXXXX`, jamais le caractère brut, que des outils d'édition perdent ou transforment. Contrôle (aucune
  exception) :
  `grep -nP '[\x{E000}-\x{F8FF}]' shared/*.qml app/qml/*.qml app/agentburn/*.py`.
- Textes venus du CLI affichés en `Text.PlainText` ; process lancés en argv ; écritures atomiques.
- Un raccourci volontaire porte un commentaire `shortcut: <limite>, <quand y revenir>`.
- Code propre à une plateforme dans `platform_win.py` ou `platform_linux.py`, dossiers dans `paths.py` seulement.
- À garder synchrones : l'identifiant `io.github.magikdidi24.AgentBurn` (fichier `.desktop`, icônes, AppStream,
  `setDesktopFileName`, autostart), le nom d'application `AgentBurn` (`WM_CLASS` sous X11 ↔
  `StartupWMClass`), les exécutables `AgentBurn.exe` et `agent-burn-desktop`, le CLI dans `<dossier de l'exe>/bin/`,
  les clés de `build-info.json` (`appVersion`, `cliRev`, `cliVersion`, `target`, `builtAt`) écrites par les
  deux scripts de build, l'empreinte de l'image de build (workflow et `linux/build-local.sh`), les sommes des
  polices JetBrainsMono Nerd Font extraites (`linux/build.sh` et `build.ps1`) et la version dans la clé de leur
  cache (workflow).

## ARM64

- **Windows ARM64** : `build.ps1 -Arch arm64` sur une machine ARM64 avec un Python ARM64 (pas de compilation
  croisée). La CI le construit sur `windows-11-arm`, au lancement manuel seulement, en expérimental et hors des
  releases ; jamais lancé à ce jour. L'installeur arm64 n'a été
  que compilé sous Wine ; PyPI publie bien les wheels `win_arm64` de PySide6 6.12 et PyInstaller (vu pendant
  l'audit). Rien n'a tourné sur du matériel ARM.
- L'installeur x64 accepte Windows 11 ARM, qui l'émule : jamais essayé.
- **Linux ARM64** : pas de build (`build.sh`, nfpm et l'AppImage visent x86_64).
