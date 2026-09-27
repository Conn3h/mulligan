import AppKit
import SwiftUI

/// The menu bar item's dropdown (spec §6.14). `SottoApp` swaps the item's own icon between
/// `waveform` and `waveform.circle.fill` as `controller.state.isActive` changes; this view is
/// only the menu below it.
@MainActor
struct MenuBarContent: View {
    let controller: DictationController

    @Environment(\.openWindow) private var openWindow
    @State private var status = PermissionStatus.shared

    var body: some View {
        Group {
            Text("Hold \(Settings.shared.pushToTalkKey.displayName) to dictate")
                .disabled(true)

            if Settings.shared.eraseKey != .off {
                Text("\(Settings.shared.pushToTalkKey.displayName) + \(Settings.shared.eraseKey.displayName) erases the last one")
                    .disabled(true)
            }

            Divider()

            Button("Open Sotto") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }

            SettingsLink {
                Text("Settings…")
            }

            if !status.hasAccessibility {
                Button("Grant Accessibility…") {
                    Permissions.openAccessibilitySettings()
                }
            }

            if !status.hasMicrophone {
                Button("Grant Microphone…") {
                    Permissions.openMicrophoneSettings()
                }
            }

            Divider()

            Button("Quit Sotto") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        // Opening a menu-bar menu need not activate the app, so app-activation refresh alone
        // can leave this stale; refresh once per menu open instead of once per body eval.
        .onAppear {
            PermissionStatus.shared.refresh()
        }
    }
}
