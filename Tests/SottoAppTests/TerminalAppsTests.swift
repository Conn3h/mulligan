import Testing
@testable import Sotto

/// Terminals expose their whole screen through Accessibility, not the line being edited, so
/// their text can never prove what Sotto typed (§6.16).
struct TerminalAppsTests {
    @Test(arguments: [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "com.github.wez.wezterm",
        "net.kovidgoyal.kitty", "org.alacritty", "dev.warp.Warp-Stable",
    ])
    func knownTerminalsAreTerminals(_ bundleID: String) {
        #expect(TerminalApps.isTerminal(bundleID: bundleID))
    }

    @Test(arguments: ["com.apple.TextEdit", "com.microsoft.VSCode", "com.google.Chrome", "com.openai.codex"])
    func otherAppsAreNot(_ bundleID: String) {
        #expect(!TerminalApps.isTerminal(bundleID: bundleID))
    }

    @Test func anUnknownAppIsNot() {
        #expect(!TerminalApps.isTerminal(bundleID: nil))
    }
}
