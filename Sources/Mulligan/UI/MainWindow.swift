import AppKit
import SwiftUI

/// The main window (spec §6.14): a slim status header in the title bar band, beside the
/// window controls, then the History or Dictionary panel on one surface below it. Hosted by
/// the `Window("Mulligan", id: "main")` scene in `MulliganApp`, whose hidden title bar lets
/// the header share the band with the window controls. Opens on the first-run welcome once.
@MainActor
struct MainWindow: View {
    let controller: DictationController

    enum Tab: Hashable {
        case history
        case dictionary
    }

    @State private var tab: Tab = .history
    @State private var showsWelcome = WelcomeGate.shows(
        hasSeenWelcome: Settings.shared.hasSeenWelcome,
        historyCount: HistoryStore.shared.runs.count
    )

    var body: some View {
        VStack(spacing: DS.Space.none) {
            StatusHeader(controller: controller, tab: $tab)
                .frame(height: DS.Metric.headerHeight)
                .padding(.leading, DS.Metric.windowControlsClearance)
                .padding(.trailing, DS.Space.base)
                .padding(.bottom, DS.Metric.headerGap)

            ContentWell {
                Group {
                    switch tab {
                    case .history:
                        HistoryPanel()
                    case .dictionary:
                        DictionaryPanel()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, DS.Space.base)
            .padding(.bottom, DS.Space.base)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(DS.Color.ground)
        .sheet(isPresented: $showsWelcome) {
            WelcomeSheet {
                Settings.shared.hasSeenWelcome = true
                showsWelcome = false
            }
        }
        .onAppear {
            // An existing install never sees the welcome; remember that so it never will.
            if !showsWelcome, !Settings.shared.hasSeenWelcome {
                Settings.shared.hasSeenWelcome = true
            }
        }
    }
}

/// The header: a status dot and word ("Ready", "Listening", "Typed 10:42"), the key hint,
/// then the History / Dictionary switch and the Record and Settings buttons. The dot is coral
/// only while recording. "Typed …" / "Saved …" holds for `DS.Motion.statusHoldSeconds` after
/// an utterance that actually produced a history run.
@MainActor
private struct StatusHeader: View {
    let controller: DictationController
    @Binding var tab: MainWindow.Tab

    /// A run captured to a completion label: equatable so a stale timer can tell it is no
    /// longer the one showing.
    private struct CompletionStatus: Equatable {
        let word: String
        let timeText: String
    }

    @State private var completion: CompletionStatus?
    @State private var completionTask: Task<Void, Never>?
    /// The newest run's id when the current utterance began, so going idle can tell whether
    /// a run was actually appended (a release) or not (an abort, or an error that timed
    /// itself back to idle) before claiming "Typed" / "Saved".
    @State private var baselineRunID: DictationRun.ID?

    private static let timeOfDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: DS.Space.base) {
            HStack(spacing: DS.Space.snug) {
                Circle()
                    .fill(controller.state.isActive ? DS.Color.accent : DS.Color.inkTertiary)
                    .frame(width: DS.Metric.statusDotSize, height: DS.Metric.statusDotSize)
                    .accessibilityHidden(true)
                Text(statusWord)
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.ink)
                    .monospacedDigit()
            }

            keyHint

            Spacer(minLength: DS.Space.base)

            SegmentedChoice(
                options: [MainWindow.Tab.history, .dictionary],
                selection: $tab,
                track: DS.Color.panel
            ) { option in
                option == .history ? "History" : "Dictionary"
            }

            recordButton

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Settings")
            .help("Settings")
        }
        .onChange(of: controller.state) { oldValue, newValue in
            handle(old: oldValue, new: newValue)
        }
        .onDisappear {
            completionTask?.cancel()
        }
    }

    private var keyHint: some View {
        let settings = Settings.shared
        return HStack(spacing: DS.Space.tight) {
            Text("hold")
            Keycap(text: settings.pushToTalkKey.displayName)
            Text("to talk")
            if settings.eraseKey != .off {
                Text("\u{00B7} tap")
                Keycap(text: settings.eraseKey.displayName)
                Text("to redo")
            }
        }
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.inkSecondary)
        .lineLimit(1)
        .fixedSize()
    }

    private var recordButton: some View {
        let isActive = controller.state.isActive
        return Button {
            if isActive {
                controller.stopButtonRecording()
            } else {
                controller.startButtonRecording()
            }
        } label: {
            Image(systemName: isActive ? "stop.fill" : "mic")
        }
        .buttonStyle(IconButtonStyle(filled: isActive ? DS.Color.accent : nil))
        .accessibilityLabel(isActive ? "Stop recording" : "Record")
        .help(isActive ? "Stop recording" : "Record here. Recordings started here are saved to History, not typed.")
    }

    private var statusWord: String {
        if controller.state.isActive {
            return "Listening"
        }
        if let completion {
            return "\(completion.word) \(completion.timeText)"
        }
        return "Ready"
    }

    private func handle(old: DictationController.State, new: DictationController.State) {
        if new.isActive, !old.isActive {
            baselineRunID = HistoryStore.shared.runs.first?.id
        }
        guard new == .idle else {
            return
        }
        defer { baselineRunID = nil }
        guard let latest = HistoryStore.shared.runs.first, latest.id != baselineRunID else {
            return
        }
        show(latest)
    }

    private func show(_ run: DictationRun) {
        completionTask?.cancel()
        let status = CompletionStatus(
            word: run.source == "hotkey" ? "Typed" : "Saved",
            timeText: Self.timeOfDay.string(from: run.date)
        )
        completion = status
        completionTask = Task {
            do {
                try await Task.sleep(for: .seconds(DS.Motion.statusHoldSeconds))
            } catch {
                Log.app.debug("header status timer cancelled")
                return
            }
            guard completion == status else {
                return
            }
            completion = nil
        }
    }
}
