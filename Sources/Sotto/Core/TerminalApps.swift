/// Terminal emulators. Their Accessibility text is the whole screen buffer, not the line the
/// user is editing, so it can never prove what Sotto typed: erase treats them as unreadable
/// and relies on the unchanged-input rule instead (§6.16).
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

    static func isTerminal(bundleID: String?) -> Bool {
        guard let bundleID else {
            return false
        }
        return bundleIDs.contains(bundleID)
    }
}
