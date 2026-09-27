/// Terminal emulators. The terminal screen's Accessibility text is the whole screen buffer,
/// not the line the user is editing, so it can never prove what Sotto typed: erase relies on
/// the unchanged-input rule there, while still checking the field and window (§6.16). A real
/// text field inside a terminal app (search, rename) is an ordinary readable field.
enum TerminalApps {
    private static let bundleIDs: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "dev.warp.Warp-Stable",
    ]

    /// Roles of genuine text fields, which read back like any other app's.
    private static let textFieldRoles: Set<String> = ["AXTextField", "AXComboBox"]

    /// True for a terminal app's screen: anything focused in a terminal that is not a real
    /// text field.
    static func isScreen(bundleID: String?, role: String?) -> Bool {
        guard isTerminal(bundleID: bundleID) else {
            return false
        }
        return !(role.map(textFieldRoles.contains) ?? false)
    }

    static func isTerminal(bundleID: String?) -> Bool {
        guard let bundleID else {
            return false
        }
        return bundleIDs.contains(bundleID)
    }
}
