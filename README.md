# Agent Burn pour Windows

Portage Windows du module Quickshell **Agent Burn** (recréation de l'app macOS
[agent-burn](https://github.com/Melvynx/agent-burn)) : conso Claude Code et limites live dans une
**icône de la zone de notification**, un **popover** et un **dashboard**, sur le même CLI `agent-burn`.

Les vues sont **les mêmes fichiers QML que sous Linux** (`config/quickshell/Burn.qml`, `BurnPopover.qml`,
`BurnDashboardView.qml`, `BurnQuotaChart.qml`, `BurnBarChart.qml`, `assets/burn/`) : une couche de
compatibilité PySide6 fournit les quelques types Quickshell qu'ils utilisent. Seules les fenêtres propres
à Windows vivent dans `app/`. Une correction du QML partagé profite donc aux deux plateformes.

## Installer

1. Sur GitHub, onglet **Actions** → workflow **Agent Burn (Windows)** → dernier run réussi → artefact
   **AgentBurn-windows** (le workflow se relance à chaque push qui touche l'app, le QML partagé ou
   `install.sh` ; sinon **Run workflow**).
2. Dézipper puis lancer `AgentBurn-Setup-<version>.exe` : installation pour l'utilisateur seul, sans droits
   admin (`%LOCALAPPDATA%\Programs\Agent Burn`), raccourci dans le menu Démarrer, case « Lancer Agent Burn
   au démarrage de Windows », lancement en fin d'installation.
3. **SmartScreen** : l'installeur n'est pas signé, Windows affiche « Windows a protégé votre ordinateur »
   → **Informations complémentaires** → **Exécuter quand même**.

Sans installation : `AgentBurn-portable-<version>.zip` (même artefact), dézipper où l'on veut et lancer
`AgentBurn\AgentBurn.exe`.

Prérequis : Claude Code installé et connecté sur ce PC (`claude` puis `/login`) ; le CLI lit son
historique et sa session dans `%USERPROFILE%\.claude`.

## Fonctionnalités

- Icône de la zone de notification comme le pill de la barre Linux : % restant de la limite la plus
  serrée sur une pastille teintée selon le rythme (grise sur un relevé ancien), lisible dès 16 px ;
  flamme grise tant qu'il n'y a pas de données.
- Clic : popover posé contre l'icône (onglets Général / agent, graphe de rythme). Clic droit : ouvrir le
  dashboard, rafraîchir, lancer au démarrage de Windows, à propos, quitter.
- Dashboard : limites live, dépense, modèles, historique (mêmes pages que sous Linux). Relancer Agent Burn
  alors qu'il tourne déjà ouvre ce dashboard.
- Rafraîchissement identique au module Linux (logique de `Burn.qml`, partagée) : bilan au démarrage puis
  en fond, limites toutes les 5 min, rien pendant l'inactivité.
- Suit le thème clair/sombre et la couleur d'accentuation de Windows ; police JetBrainsMono Nerd Font
  embarquée.
- Démarrage avec Windows : valeur `AgentBurn` de `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`,
  posée par l'installeur ou par le menu de l'icône.

## Données

| Quoi | Où | Variable pour le changer |
|---|---|---|
| Historique (`burn-history.json`, `burn-quota.json`) | `%APPDATA%\AgentBurn` | `AGENT_BURN_DATA` |
| CLI `agent-burn.exe` | `<dossier d'installation>\bin\` | `AGENT_BURN_BIN` |

L'historique archive chaque jour : il survit à la purge des logs de Claude Code (30 jours), aux mises à
jour et à la désinstallation.

## Compiler en local

Windows 10/11 x64 avec :
- **PowerShell 7.4+** (`winget install Microsoft.PowerShell`) ;
- **Python 3.12** (python.org, cocher « Add python.exe to PATH ») ;
- **Rust** via [rustup](https://rustup.rs) (toolchain MSVC ; rustup propose les Build Tools C++ de Visual Studio) ;
- **Inno Setup 6.3+** ([jrsoftware.org](https://jrsoftware.org/isdl.php)).

```powershell
pwsh -File windows\agent-burn\build.ps1            # CLI, polices, bundle, selftest, zip, installeur
pwsh -File windows\agent-burn\build.ps1 -SkipCli   # sans Rust : réutilise le build\cli d'un build précédent
```

Sorties dans `windows\agent-burn\dist\` : `AgentBurn\` (bundle), `AgentBurn-portable-<version>.zip`,
`AgentBurn-Setup-<version>.exe` et `selftest\` (captures du tray, du popover et du dashboard,
`selftest.json`, `stderr.txt`). Relançable : venv, polices et CLI déjà compilé pour `AB_REV` sont réutilisés. Le build
échoue si le selftest du bundle (popover et dashboard rendus quelques secondes à l'écran, sur les sorties
réelles du CLI de `tests\fixtures`) relève une erreur ou un avertissement Qt/QML, ne charge pas les
données, voit un appel du CLI échouer ou ne peut pas capturer une vue : ne pas cliquer dessus pendant ce temps.

Le CLI est compilé depuis la révision épinglée dans `install.sh` (`AB_REV` / `AB_VER`, partagée avec
Linux). Pour suivre l'amont, `agent-burn-upstream` (module Linux) liste ce qui a changé et
`agent-burn-upstream --bump` met `install.sh` à jour : une fois ce changement poussé, le workflow Windows
recompile le CLI tout seul.

## Tests (sous Linux)

Depuis `desktop/agent-burn/app`, avec un Python où PySide6 6.12 est installé :

```sh
python -m unittest discover -s tests          # faux CLI, popover, icône, dossier QML, registre factice
python tests/run_burn_suite.py                # suite de Burn.qml sous la couche de compatibilité (code 1 si échec)
AGENT_BURN_FAKE_DIR=$PWD/../tests/fixtures AGENT_BURN_BIN=$PWD/tests/fake-agent-burn \
    AGENT_BURN_DATA=/tmp/agent-burn-selftest python -m agentburn --selftest /tmp/agent-burn-shots
```

La même suite tourne sous Quickshell (`tests/burn-suite/shell.qml`, lancement en tête du fichier) : les deux
doivent donner le même résultat, c'est le contrôle de fidélité de la couche de compatibilité à Quickshell.

## Désinstaller

Paramètres → Applications → Applications installées → **Agent Burn** → Désinstaller. L'app est arrêtée et
la valeur de démarrage `AgentBurn` retirée ; `%APPDATA%\AgentBurn` est **conservé** (une réinstallation
retrouve l'historique) : le supprimer à la main pour tout effacer. Version portable : décocher « Lancer au
démarrage de Windows » dans le menu de l'icône s'il est coché, quitter, puis supprimer le dossier.

## Limites

- Non signé : avertissement SmartScreen, et certains antivirus se méfient des exécutables PyInstaller.
- x64 seulement (Windows 11 ARM le lance en émulation).
- Pas de mise à jour automatique : réinstaller l'artefact d'un build plus récent (l'installation existante
  est remplacée).
- Le selftest de la CI capture les vues sans icône de notification : le comportement réel du tray
  (position du popover, plusieurs écrans, mise à l'échelle) se vérifie sur un vrai bureau Windows.
- Gros (Qt Quick et Python embarqués), comme toute app PySide6.
