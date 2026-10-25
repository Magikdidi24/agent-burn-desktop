pragma Singleton
import QtQuick

// Desktop app colors, same API as Quickshell's Colors.qml: theme chosen in the settings,
// or the system light/dark followed live, and its accent color; backgrounds and grays from the Mac app.
QtObject {
    id: root

    property string theme: "system"   // app setting (Main.qml): system, light or dark
    // Explicit rather than through styleHints.setColorScheme, which some platforms ignore; unknown
    // system scheme (no portal): dark.
    readonly property bool dark: theme === "dark" || theme !== "light" && Qt.styleHints.colorScheme !== Qt.ColorScheme.Light
    readonly property color background: dark ? "#1c1c1e" : "#ececf0"
    readonly property color foreground: dark ? "#f5f5f7" : "#1d1d1f"
    readonly property color surface: dark ? "#363638" : "#ffffff"   // cards: surface at 55% over the background
    readonly property color muted: dark ? "#98989f" : "#5e5e63"   // secondary text: ≥ 4.5:1 on background and cards
    readonly property color good: dark ? "#30d158" : "#248a3d"
    readonly property color warn: dark ? "#ff9f0a" : "#c93400"
    readonly property color danger: dark ? "#ff453a" : "#d70015"
    readonly property color color5: dark ? "#bf5af2" : "#8944ab"
    readonly property color accentAlt: dark ? "#64d2ff" : "#0071a4"
    // Windows accent, lightened (dark) or darkened (light) up to 4.5:1 contrast on the cards
    // and the background: used as text and as the fill behind background-colored text (active tab).
    readonly property color accent: readable(system.accent)

    readonly property SystemPalette system: SystemPalette {}

    function withAlpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }

    function luminance(c) {
        const f = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
    }
    function contrast(a, b) {
        const x = luminance(a), y = luminance(b);
        return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
    }
    function readable(c) {
        const card = Qt.tint(background, withAlpha(surface, 0.55));
        for (let i = 0; i < 25 && Math.min(contrast(c, card), contrast(c, background)) < 4.5; i++)
            c = Qt.hsla(Math.max(0, c.hslHue), c.hslSaturation,
                        Math.max(0, Math.min(1, c.hslLightness + (dark ? 0.03 : -0.03))), 1);
        return c;
    }
}
