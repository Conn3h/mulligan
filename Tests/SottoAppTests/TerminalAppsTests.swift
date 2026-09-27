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

    /// Inside a terminal app, a real text field (search, rename) is an ordinary readable
    /// field; anything else is the screen (Codex, round 4).
    @Test func aTerminalsTextFieldIsNotItsScreen() {
        #expect(!TerminalApps.isScreen(bundleID: "com.googlecode.iterm2", role: "AXTextField"))
        #expect(!TerminalApps.isScreen(bundleID: "com.googlecode.iterm2", role: "AXComboBox"))
        #expect(TerminalApps.isScreen(bundleID: "com.googlecode.iterm2", role: "AXTextArea"))
        #expect(TerminalApps.isScreen(bundleID: "com.mitchellh.ghostty", role: nil))
    }

    @Test func nothingOutsideATerminalIsAScreen() {
        #expect(!TerminalApps.isScreen(bundleID: "com.apple.TextEdit", role: "AXTextArea"))
    }
}
