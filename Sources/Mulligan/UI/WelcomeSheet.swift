import AppKit
import SwiftUI

/// The first-run welcome (spec §6.14): the mark, the two keys, and the two permissions with
/// their state, on one sheet over the main window. Shown once (`WelcomeGate`); "Start
/// dictating" sets `Settings.hasSeenWelcome` through `onDone`.
@MainActor
struct WelcomeSheet: View {
    let onDone: () -> Void

    @State private var status = PermissionStatus.shared

    var body: some View {
        let settings = Settings.shared
        VStack(alignment: .leading, spacing: DS.Space.wide) {
            HStack(spacing: DS.Space.roomy) {
                TeeShotMark(level: 0, isRecording: false, restingArcs: true)
                    .frame(width: DS.Metric.welcomeGlyphHeight, height: DS.Metric.welcomeGlyphHeight)
                VStack(alignment: .leading, spacing: DS.Space.tight) {
                    Text("Welcome to Mulligan")
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Color.ink)
                    Text("Dictation that stays on your Mac, with a free second shot.")
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
            }

            VStack(alignment: .leading, spacing: DS.Space.base) {
                step(
                    keys: [settings.pushToTalkKey.displayName],
                    text: "Hold it anywhere and talk. Let go, and your words are typed where the cursor is."
                )
                if settings.eraseKey != .off {
                    step(
                        keys: [settings.pushToTalkKey.displayName, settings.eraseKey.displayName],
                        text: "Came out wrong? Hold the talk key and tap the other one. The last dictation is erased, so you can say it again."
                    )
                }
            }

            VStack(alignment: .leading, spacing: DS.Space.snug) {
                SectionHeader(title: "Permissions")
                PermissionRow(
                    title: "Accessibility",
                    purpose: "to hear the keys and type for you",
                    granted: status.hasAccessibility,
                    open: Permissions.openAccessibilitySettings
                )
                PermissionRow(
                    title: "Microphone",
                    purpose: "to hear you",
                    granted: status.hasMicrophone,
                    open: Permissions.openMicrophoneSettings
                )
            }

            HStack {
                Spacer()
                Button("Start dictating", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.panel)
        .frame(width: DS.Metric.welcomeWidth)
        .background(DS.Color.panel)
        .onAppear {
            PermissionStatus.shared.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            PermissionStatus.shared.refresh()
        }
    }

    private func step(keys: [String], text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.base) {
            HStack(spacing: DS.Space.tight) {
                ForEach(keys.indices, id: \.self) { index in
                    if index > 0 {
                        Text("+")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.inkTertiary)
                    }
                    Keycap(text: keys[index])
                }
            }
            .fixedSize()
            Text(text)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One permission: its name, what it is for, and either a check or a "Grant…" button that
/// opens the right pane of System Settings. Shared by the welcome sheet and Settings.
@MainActor
struct PermissionRow: View {
    let title: String
    var purpose: String?
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.base) {
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(title)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                if let purpose {
                    Text(purpose)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkTertiary)
                }
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            } else {
                Button("Grant\u{2026}", action: open)
            }
        }
    }
}
