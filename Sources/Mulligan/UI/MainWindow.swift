import SwiftUI

/// The main window (spec §6.14): the masthead — the instrument's face, with the Record key,
/// the full-width level meter and the elapsed/status readout — then a History / Dictionary
/// tab area. Hosted by the `Window("Mulligan", id: "main")` scene in `MulliganApp`, which gives it
/// a hidden title bar so this view's own `ground` fill reads as one matte plate under it.
@MainActor
struct MainWindow: View {
    let controller: DictationController

    private enum Tab: Hashable {
        case history
        case dictionary
    }

    @State private var tab: Tab = .history
    @State private var windowVisible = true

    var body: some View {
        VStack(spacing: DS.Space.none) {
            Masthead(controller: controller, windowVisible: windowVisible)
                .padding(.horizontal, DS.Space.panel)
                .padding(.bottom, DS.Space.panel)
                // The hidden title bar already contributes its own inset above.
                .padding(.top, DS.Space.wide)

            Rectangle()
                .fill(DS.Color.hairlineStrong)
                .frame(height: DS.Border.hairline)

            VStack(spacing: DS.Space.none) {
                TextTabs(
                    options: [Tab.history, .dictionary],
                    selection: $tab,
                    count: { option in
                        option == .history ? HistoryStore.shared.runs.count : nil
                    },
                    label: { option in
                        switch option {
                        case .history: "History"
                        case .dictionary: "Dictionary"
                        }
                    }
                )
                .padding(.horizontal, DS.Space.roomy)
                .padding(.vertical, DS.Space.roomy)

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
                .padding(.horizontal, DS.Space.roomy)
                .padding(.bottom, DS.Space.roomy)
            }
        }
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .background(DS.Color.ground)
    }
}

/// The instrument's face: the Record key, the full-width masthead meter, and the elapsed
/// counter with its status eyebrow beneath it. The status word reads "LISTENING" while
/// active, "READY" at rest, or — for `DS.Motion.statusHoldSeconds` after an utterance that
/// actually produced a history run — "TYPED …" / "RECORDED …" with that run's time.
@MainActor
private struct Masthead: View {
    let controller: DictationController
    let windowVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A run captured to a completion label: equatable so a stale timer can tell it is no
    /// longer the one showing (mirrors `HistoryRow`'s copy-feedback generation guard).
    private struct CompletionStatus: Equatable {
        let word: String
        let timeText: String
    }

    @State private var completion: CompletionStatus?
    @State private var completionTask: Task<Void, Never>?
    /// The newest run's id when the current utterance began, so going idle can tell whether
    /// a run was actually appended (a release) or not (an abort, or an error that timed
    /// itself back to idle) before claiming "TYPED" / "RECORDED".
    @State private var baselineRunID: DictationRun.ID?

    private static let timeOfDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.roomy) {
                RecordKey(controller: controller)

                MastheadMeterView(
                    level: controller.level,
                    isActive: controller.state.isActive,
                    reduceMotion: reduceMotion,
                    windowVisible: windowVisible
                )
                .frame(maxWidth: .infinity)

                statusReadout
            }

            Text("Recordings started here are saved to History, not typed.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkTertiary)
        }
        .onChange(of: controller.state) { oldValue, newValue in
            handle(old: oldValue, new: newValue)
        }
        .onDisappear {
            completionTask?.cancel()
        }
    }

    private var statusReadout: some View {
        VStack(alignment: .trailing, spacing: DS.Space.tight) {
            ElapsedReadout(
                holdStartedAt: controller.holdStartedAt,
                isActive: controller.state.isActive,
                windowVisible: windowVisible
            )

            HStack(spacing: DS.Space.tight) {
                if controller.state.isActive {
                    Circle()
                        .fill(DS.Color.accent)
                        .frame(width: DS.Metric.lampSize, height: DS.Metric.lampSize)
                        .accessibilityLabel("Recording")
                }
                Text(statusWord)
                    .font(DS.Font.eyebrow)
                    .tracking(DS.Metric.eyebrowTracking)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
        }
    }

    private var statusWord: String {
        if controller.state.isActive {
            return "LISTENING"
        }
        if let completion {
            return "\(completion.word) \(completion.timeText)"
        }
        return "READY"
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
            word: run.source == "hotkey" ? "TYPED" : "RECORDED",
            timeText: Self.timeOfDay.string(from: run.date)
        )
        completion = status
        completionTask = Task {
            do {
                try await Task.sleep(for: .seconds(DS.Motion.statusHoldSeconds))
            } catch {
                Log.app.debug("masthead status timer cancelled")
                return
            }
            guard completion == status else {
                return
            }
            completion = nil
        }
    }
}

/// Record/Stop: a pill with an ink outline at rest, a coral fill and `inkOnAccent` label
/// while recording, and a small scale-down on press.
@MainActor
private struct RecordKey: View {
    let controller: DictationController

    var body: some View {
        Button {
            if controller.state.isActive {
                controller.stopButtonRecording()
            } else {
                controller.startButtonRecording()
            }
        } label: {
            Text(controller.state.isActive ? "Stop" : "Record")
                .frame(minWidth: DS.Metric.keycapMinWidth)
        }
        .buttonStyle(RecordKeyStyle(isActive: controller.state.isActive))
    }
}

@MainActor
private struct RecordKeyStyle: ButtonStyle {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.label)
            .foregroundStyle(isActive ? DS.Color.inkOnAccent : DS.Color.ink)
            .padding(.horizontal, DS.Space.roomy)
            .padding(.vertical, DS.Space.snug)
            .background(Capsule().fill(isActive ? DS.Color.accent : DS.Color.clear))
            .overlay(
                Capsule().stroke(isActive ? DS.Color.clear : DS.Color.ink, lineWidth: DS.Border.hairline)
            )
            .scaleEffect(configuration.isPressed ? DS.Metric.pressedScale : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: DS.Motion.quick),
                value: configuration.isPressed
            )
    }
}

/// Tabular-digit `mm:ss.t` elapsed time, ticking from `holdStartedAt` while active and
/// resting at zero otherwise.
@MainActor
private struct ElapsedReadout: View {
    let holdStartedAt: Date?
    let isActive: Bool
    let windowVisible: Bool

    private static let idleText = "00:00.0"
    private static let locale = Locale(identifier: "en_US_POSIX")

    var body: some View {
        // No per-frame text rebuilds at rest, or behind another window while recording.
        if isActive && windowVisible {
            TimelineView(.periodic(from: .now, by: DS.Motion.elapsedTick)) { context in
                readout(text(now: context.date))
            }
        } else {
            readout(isActive ? text(now: Date()) : Self.idleText)
        }
    }

    private func readout(_ string: String) -> some View {
        Text(string)
            .font(DS.Font.readoutLarge)
            .foregroundStyle(DS.Color.ink)
    }

    private func text(now: Date) -> String {
        guard isActive, let holdStartedAt else {
            return Self.idleText
        }
        let elapsed = max(0, now.timeIntervalSince(holdStartedAt))
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        let tenths = Int((elapsed - elapsed.rounded(.down)) * 10)
        return String(format: "%02d:%02d.%d", locale: Self.locale, minutes, seconds, tenths)
    }
}
