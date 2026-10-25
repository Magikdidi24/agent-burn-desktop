pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Fusion
import QtQuick.Layouts
import AgentBurn

// "Settings" window of the desktop app: settings, provider status, diagnostics, about.
// Qt Quick controls (Tab, arrows, Space or Enter, screen readers) in the Colors palette: readable in light
// and dark. Esc closes it; opened from the tray icon menu (Main.openSettings).
ApplicationWindow {
    id: win

    readonly property var sections: ["general", "providers", "diagnostic", "about"]
    property int section: 0
    readonly property color card: Qt.tint(Colors.background, Colors.withAlpha(Colors.surface, 0.55))
    readonly property var agents: Array.from(new Set(Burn.knownProviders.concat(Burn.agents)))
    // Source of a Burn.recentErrors error, in plain words.
    readonly property var sources: ({ summary: "Report", range: "Dashboard period", "harness:claude": "Claude Code details",
                                      "harness:codex": "Codex details", quota: "Limits reading", cli: "CLI launch" })

    function open(name) {
        section = Math.max(0, sections.indexOf(name));
        tabs.currentItem.forceActiveFocus();   // not on a hidden control of the section left: Space would change it
        visible = true;
        raise();
        requestActivate();
    }
    // Enter works like Space on the focused control: button, switch, option or tab.
    function activate(event) {
        const f = win.activeFocusItem;
        if (typeof f?.click === "function")
            f.click();
        else
            event.accepted = false;
    }
    function stateColor(s) {
        return s === "live" ? Colors.good : s === "unavailable" ? Colors.danger
             : s === "none" || s === "unknown" ? Colors.muted : Colors.warn;
    }

    title: "Settings — Agent Burn"
    width: 620
    height: 680
    minimumWidth: 520
    minimumHeight: 480
    color: Colors.background
    font.family: "JetBrainsMono Nerd Font"
    font.pixelSize: 13
    palette {
        window: Colors.background
        windowText: Colors.foreground
        base: win.card
        alternateBase: Colors.background
        text: Colors.foreground
        button: win.card
        buttonText: Colors.foreground
        brightText: Colors.foreground
        highlight: Colors.accent
        highlightedText: Colors.background
        placeholderText: Colors.muted
        toolTipBase: win.card
        toolTipText: Colors.foreground
        mid: Colors.withAlpha(Colors.muted, 0.5)
        dark: Colors.withAlpha(Colors.muted, 0.7)
        light: Colors.withAlpha(Colors.foreground, 0.15)
        midlight: Colors.withAlpha(Colors.foreground, 0.08)
        disabled.text: Colors.muted
        disabled.windowText: Colors.muted
        disabled.buttonText: Colors.muted
    }

    onVisibleChanged: if (visible) Desktop.probeCli()
    Shortcut { sequence: "Esc"; onActivated: win.close() }

    header: TabBar {
        id: tabs
        currentIndex: win.section
        onCurrentIndexChanged: win.section = currentIndex
        Accessible.name: "Settings sections"
        Keys.onReturnPressed: event => win.activate(event)
        Keys.onEnterPressed: event => win.activate(event)
        PageTab { text: "General" }
        PageTab { text: "Providers" }
        PageTab { text: "Diagnostics" }
        PageTab { text: "About" }
    }

    // Keyboard focus ring, the same as in the shared views (BurnButton): the style draws none on
    // tabs and barely one on radio buttons.
    component Ring: Rectangle {
        z: 1
        anchors.fill: parent
        color: "transparent"
        border.width: 2
        border.color: Colors.accent
        radius: 4
    }
    // Tab: current section underlined and bold, not just tinted.
    component PageTab: TabButton {
        id: tab
        font.bold: checked
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 3
            visible: tab.checked
            color: Colors.accent
        }
        Ring { visible: tab.visualFocus }
    }
    // Option in a row: the left or right arrow moves to the neighbor and checks it at once, as on Windows or GTK.
    component Choice: RadioButton {
        id: choice
        function step(d) {
            const row = Array.from(parent.children).filter(c => c instanceof RadioButton);
            const next = row[row.indexOf(choice) + d];
            if (next) {
                next.forceActiveFocus(Qt.TabFocusReason);   // ring kept, as with Tab
                next.click();
            }
        }
        Keys.onLeftPressed: step(-1)
        Keys.onRightPressed: step(1)
        Ring { visible: choice.visualFocus }
    }

    // Section text; CLI texts (errors, paths, versions) never interpreted.
    component Txt: Label {
        Layout.fillWidth: true
        color: Colors.foreground
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
    }
    component Hint: Txt {
        color: Colors.muted
        font.pixelSize: 11
    }
    // Label: value, wrapped between words or anywhere; a path, anywhere (otherwise "C:" would be left
    // alone at the end of a line, its only break between two words).
    component Field: RowLayout {
        id: field
        property string label
        property string value
        property bool path
        Layout.fillWidth: true
        spacing: 12
        Txt {
            text: field.label
            color: Colors.muted
            Layout.fillWidth: false
            Layout.preferredWidth: 170
            Layout.alignment: Qt.AlignTop
        }
        Txt { text: field.value; wrapMode: field.path ? Text.WrapAnywhere : Text.WrapAtWordBoundaryOrAnywhere }
    }
    component Group: GroupBox {
        Layout.fillWidth: true
        // Fusion GroupBox: title and frame in the palette colors.
        default property alias content: box.data
        ColumnLayout {
            id: box
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 10
        }
    }
    // Scrolling page of a section.
    component Page: ScrollView {
        id: page
        default property alias content: col.data
        contentWidth: availableWidth
        padding: 20
        ColumnLayout {
            id: col
            width: page.availableWidth
            spacing: 16
        }
    }

    // Content created only on opening: closed window = no bindings, no clock.
    Loader {
        anchors.fill: parent
        active: win.visible
        sourceComponent: StackLayout {
            id: stack
            currentIndex: tabs.currentIndex
            Keys.onReturnPressed: event => win.activate(event)
            Keys.onEnterPressed: event => win.activate(event)

            // Control reached by keyboard outside the view: the page scrolls to it.
            Connections {
                target: win
                function onActiveFocusItemChanged() {
                    const f = stack.children[stack.currentIndex]?.contentItem;   // Flickable of the shown ScrollView
                    const item = win.activeFocusItem;
                    let inside = false;
                    for (let p = item; p && !inside; p = p.parent)
                        inside = p === f;
                    if (!inside)
                        return;
                    const y = item.mapToItem(f.contentItem, 0, 0).y, top = y - 12, bottom = y + item.height + 12;
                    if (top < f.contentY)
                        f.contentY = Math.max(0, top);
                    else if (bottom > f.contentY + f.height)
                        f.contentY = Math.min(bottom - f.height, Math.max(0, f.contentHeight - f.height));
                }
            }

            // ── General ──
            Page {
                Group {
                    title: "Data"
                    RowLayout {
                        spacing: 12
                        Txt { text: "Auto refresh" }
                        ComboBox {
                            readonly property var minutes: [1, 5, 15, 30]
                            model: ["1 min", "5 min", "15 min", "30 min"]
                            currentIndex: minutes.indexOf(Settings.refreshMinutes)
                            onActivated: i => Settings.refreshMinutes = minutes[i]
                            Accessible.name: "Auto refresh"
                        }
                    }
                    Hint { text: "Limits read at this interval, full report at least once an hour." }
                }
                Group {
                    title: "Appearance"
                    RowLayout {
                        spacing: 12
                        Txt { text: "Theme"; Layout.fillWidth: false; Layout.preferredWidth: 170 }
                        Repeater {
                            model: [["system", "System"], ["light", "Light"], ["dark", "Dark"]]
                            Choice {
                                required property var modelData
                                text: modelData[1]
                                checked: Settings.theme === modelData[0]
                                onToggled: Settings.theme = modelData[0]
                                Accessible.name: "Theme " + text
                            }
                        }
                    }
                }
                Group {
                    title: "Startup and system tray"
                    Switch {
                        text: "Start at login"
                        enabled: Settings.autostartAvailable
                        opacity: enabled ? 1 : 0.5   // the style keeps the label in its normal color
                        checked: Settings.autostart
                        onToggled: Settings.autostart = checked
                    }
                    Hint { visible: !Settings.autostartAvailable; text: "Available in the installed app." }
                    Switch {
                        text: "Keep in the system tray when closed"
                        checked: Settings.closeToTray
                        onToggled: Settings.closeToTray = checked
                    }
                    RowLayout {
                        spacing: 12
                        Txt { text: "Icon click"; Layout.fillWidth: false; Layout.preferredWidth: 170 }
                        Repeater {
                            model: [["popover", "Popover"], ["dashboard", "Dashboard"]]
                            Choice {
                                required property var modelData
                                text: modelData[1]
                                checked: Settings.trayClick === modelData[0]
                                onToggled: Settings.trayClick = modelData[0]
                                Accessible.name: "Icon click: " + text
                            }
                        }
                    }
                    Hint {
                        visible: text !== ""
                        text: !Desktop.trayAvailable ? "No system tray detected: closing the dashboard quits the app. "
                                + "On GNOME, enable the AppIndicator extension."
                            : Desktop.platformName === "wayland"
                                ? "On Wayland, the desktop places the popover itself, often in the center of the screen." : ""
                    }
                }
            }

            // ── Providers ──
            Page {
                Repeater {
                    model: win.agents
                    Group {
                        id: agentBox
                        required property string modelData
                        readonly property var st: Burn.providerState(modelData)
                        title: Burn.agentName(modelData)
                        RowLayout {
                            spacing: 12
                            Rectangle {
                                Layout.alignment: Qt.AlignTop
                                implicitWidth: 32
                                implicitHeight: 32
                                radius: 8
                                color: Colors.withAlpha(Burn.agentColor(agentBox.modelData), 0.25)
                                Image {
                                    anchors.fill: parent
                                    anchors.margins: 2
                                    source: Burn.agentIcon(agentBox.modelData)
                                    sourceSize: Qt.size(64, 64)
                                    mipmap: true
                                    Accessible.ignored: true
                                }
                            }
                            ColumnLayout {
                                spacing: 4
                                // Tinted dot, word in the text color: readable whatever the tint.
                                RowLayout {
                                    spacing: 6
                                    Txt {
                                        text: "●"
                                        color: win.stateColor(agentBox.st.state)
                                        Layout.fillWidth: false
                                        Accessible.ignored: true
                                    }
                                    Txt { text: agentBox.st.label; font.bold: true }
                                }
                                Txt { text: agentBox.st.detail }
                                Hint { visible: agentBox.st.at > 0 && agentBox.st.state !== "none"; text: "Last reading " + Burn.ago(agentBox.st.at) }
                                Txt { visible: text !== ""; text: agentBox.st.error; color: Colors.danger }
                            }
                        }
                    }
                }
                Group {
                    title: "agent-burn CLI"
                    Field { label: "Location"; value: Burn.bin; path: true }
                    Field { label: "Version"; value: Desktop.cliVersion || "reading…" }
                    Field {
                        label: "Report"
                        value: Burn.stateText(Burn.dataState) + (Burn.updatedAt > 0 ? ", updated " + Burn.ago(Burn.updatedAt) : "")
                            + (Burn.error ? "\n" + Burn.error : "")   // cause of a CLI failure
                    }
                    Button {
                        text: Burn.loading ? "Reading…" : "Refresh now"
                        enabled: !Burn.loading
                        onClicked: Burn.refresh(true)
                    }
                }
            }

            // ── Diagnostics ──
            Page {
                Rectangle {
                    visible: Settings.recovered
                    Layout.fillWidth: true
                    implicitHeight: notice.implicitHeight + 20
                    radius: 8
                    color: Colors.withAlpha(Colors.warn, 0.15)
                    border.color: Colors.withAlpha(Colors.warn, 0.5)
                    Txt {
                        id: notice
                        anchors.fill: parent
                        anchors.margins: 10
                        text: "Settings reset: the settings file was unreadable, a copy was kept (settings.json.bak)."
                    }
                }
                Group {
                    title: "Versions"
                    Field {
                        label: "Agent Burn"
                        value: Desktop.appVersion + (Desktop.buildInfo.builtAt ? ", built on " + Desktop.buildInfo.builtAt : "")
                            + (Desktop.buildInfo.target === "dev" ? " (development version)" : "")
                    }
                    Field { label: "agent-burn CLI"; value: Desktop.cliVersion || "reading…" }
                    Field {
                        label: "Expected CLI"
                        value: (Desktop.buildInfo.cliVersion || "—") + (Desktop.buildInfo.cliRev ? ", revision " + Desktop.buildInfo.cliRev.slice(0, 12) : "")
                    }
                }
                Group {
                    title: "System"
                    Field { label: "System"; value: Desktop.os }
                    Field {
                        label: "Display"
                        // "Wayland (KDE)"; the session only if it differs (X11 app on Wayland: XWayland).
                        value: {
                            const name = n => ({ wayland: "Wayland", xcb: "X11", x11: "X11", windows: "Windows" })[n] ?? n;
                            const shown = name(Desktop.platformName), session = name(Desktop.sessionType);
                            const extra = [Desktop.desktopEnv, session && session !== shown ? session + " session" : ""].filter(x => x);
                            return shown + (extra.length ? " (" + extra.join(", ") + ")" : "");
                        }
                    }
                    Field { label: "Screens"; value: Desktop.screens }
                    Field { label: "System tray"; value: Desktop.trayAvailable ? "available" : "not available" }
                }
                Group {
                    title: "Folders"
                    Field { label: "Data"; value: Desktop.dataDir; path: true }
                    Field { label: "Settings"; value: Desktop.configDir; path: true }
                    Field { label: "Logs"; value: Desktop.logDir; path: true }
                    Field { label: "Cache"; value: Desktop.cacheDir; path: true }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 8
                        Button { text: "Open logs"; onClicked: Desktop.openLogs() }
                        Button { text: "Open data folder"; onClicked: Desktop.openDataDir() }
                        Button {
                            text: copied.running ? "Copied to clipboard" : "Copy diagnostics"
                            onClicked: {
                                Desktop.copyDiagnostics();
                                copied.restart();
                            }
                            Timer { id: copied; interval: 3000 }
                        }
                    }
                    Switch {
                        text: "Detailed log (debug)"
                        checked: Settings.debugLogging
                        onToggled: Settings.debugLogging = checked
                    }
                }
                Group {
                    title: "Recent errors"
                    Hint { visible: Burn.recentErrors.length === 0; text: "No errors since launch." }
                    Repeater {
                        model: Burn.recentErrors.slice().reverse()
                        Txt {
                            required property var modelData
                            text: new Date(modelData.t).toLocaleTimeString(Qt.locale("en_US"), "HH:mm:ss") + " · "
                                + (win.sources[modelData.source] ?? modelData.source) + " — " + modelData.msg
                        }
                    }
                }
                // In two steps: one press too many (Space on the last Tab stop) erases nothing.
                Button {
                    text: confirm.running ? "Confirm reset" : "Reset settings"
                    onClicked: {
                        if (confirm.running) {
                            confirm.stop();
                            Settings.reset();
                        } else {
                            confirm.start();
                        }
                    }
                    Timer { id: confirm; interval: 5000 }
                }
            }

            // ── About ──
            Page {
                RowLayout {
                    spacing: 10
                    Txt {
                        text: "\uf06d"  // fire
                        color: Colors.accent
                        font.pixelSize: 26
                        Layout.fillWidth: false
                        Accessible.ignored: true
                    }
                    Txt { text: "Agent Burn"; font.pixelSize: 20; font.bold: true }
                }
                Txt { text: "Version " + Desktop.appVersion + " · CLI " + (Desktop.cliVersion || "reading…") }
                Txt { text: "Coding agent spend (Claude Code, Codex…) and live subscription limits, read by the agent-burn CLI." }
                Txt { text: "Based on the agent-burn macOS app by Melvynx, under the MIT license." }
                Button {
                    visible: Desktop.licensesAvailable
                    text: "Licenses"
                    onClicked: Desktop.openLicenses()
                }
            }
        }
    }
}
