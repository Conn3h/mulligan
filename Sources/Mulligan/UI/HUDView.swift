import SwiftUI

/// The HUD's content (spec §6.14): the tee-shot mark on the left, whose ball is the
/// recording lamp and whose arcs are the level meter, then the two-line status text, on a
/// material card. For the first holds after a dictation, while nothing has been heard yet,
/// the second line teaches the redo gesture instead. Hosted by `HUDPanel` via
/// `NSHostingView`.
struct HUDView: View {
    let controller: DictationController

    /// Whether this hold showed the redo hint: decided once as listening starts, so using
    /// up the last hint does not pull it away mid-hold.
    @State private var hintThisHold = false

    var body: some View {
        HStack(spacing: DS.Space.base) {
            HUDMeterView(level: controller.level, state: controller.state)
                .frame(width: DS.TeeShot.width, height: DS.TeeShot.height)

            if showsHint {
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text("Listening…")
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                    Text(RedoHint.text(erase: Settings.shared.eraseKey))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HUDLabel(state: controller.state, transcript: controller.transcript)
            }
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.snug)
        .frame(width: DS.Metric.hudWidth, height: DS.Metric.hudHeight)
        .background(DS.Material.hud, in: RoundedRectangle(cornerRadius: DS.Radius.hud))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.hud)
                .strokeBorder(DS.Color.hairline, lineWidth: DS.Border.hairline)
        )
        .onChange(of: controller.state) { _, newValue in
            updateHint(for: newValue)
        }
    }

    private var showsHint: Bool {
        hintThisHold && controller.state == .listening && controller.transcript.isEmpty
    }

    private func updateHint(for state: DictationController.State) {
        let settings = Settings.shared
        switch state {
        case .listening:
            hintThisHold = RedoHint.shows(
                state: state,
                transcript: controller.transcript,
                hasErasable: DictationEraser.shared.hasErasable,
                remaining: settings.redoHintsRemaining,
                eraseKey: settings.eraseKey
            )
            if hintThisHold {
                settings.redoHintsRemaining -= 1
            }
        case .erasing:
            // Used once: the lesson is learnt.
            hintThisHold = false
            settings.redoHintsRemaining = 0
        default:
            hintThisHold = false
        }
    }
}

/// The two-line status text: "Preparing…" while `.starting`, "Listening…" while `.listening`
/// with an empty transcript, the live transcript otherwise, "Transcribing…" while
/// `.finishing` with an empty transcript, "Erasing…" while `.erasing`, or the error message
/// in `DS.Color.accent`.
/// `.idle` never renders (the HUD is dismissed then), so it falls back to empty text.
private struct HUDLabel: View {
    let state: DictationController.State
    let transcript: String

    var body: some View {
        Text(text)
            .font(DS.Font.body)
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
            .lineLimit(DS.Metric.hudLineCount, reservesSpace: true)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var text: String {
        switch state {
        case .starting:
            "Preparing…"
        case .listening:
            transcript.isEmpty ? "Listening…" : transcript
        case .finishing:
            transcript.isEmpty ? "Transcribing…" : transcript
        case .erasing:
            "Erasing…"
        case .error(let message):
            message
        case .idle:
            ""
        }
    }

    private var color: SwiftUI.Color {
        if case .error = state {
            DS.Color.accent
        } else {
            DS.Color.ink
        }
    }
}

/// The tee-shot mark as a live meter: the ball lights coral while listening, and the arcs
/// follow the level, eased so they swell and settle rather than flicker.
private struct HUDMeterView: View {
    let level: Float
    let state: DictationController.State

    /// A plain reference type the view holds (via `@State`, for stable identity across
    /// re-renders; the object itself is never reassigned). Its `advance` mutates a plain
    /// stored property, not a `@State` value, so calling it from inside the `TimelineView`
    /// closure below is safe: spec §10 warns that mutating an actual `@State` value from a
    /// `TimelineView`/`Canvas` draw closure floods the log.
    @State private var clock = HUDMeterClock()

    var body: some View {
        TimelineView(.animation(paused: !state.isActive)) { context in
            let target = state.isActive ? CGFloat(max(0, min(1, level))) : 0
            TeeShotMark(
                level: clock.advance(to: context.date, toward: target),
                isRecording: state == .listening
            )
        }
    }
}

/// See `HUDMeterView`'s doc comment: the eased level lives here, not in `@State`, so the
/// `TimelineView` closure can update it every frame without flooding the log.
@MainActor
private final class HUDMeterClock {
    private var last: Date?
    private var level: CGFloat = 0

    /// Eases the shown level toward `target`, settling in about `DS.Motion.quick`.
    func advance(to date: Date, toward target: CGFloat) -> CGFloat {
        let dt = last.map { date.timeIntervalSince($0) } ?? 0
        last = date
        let k = DS.Motion.quick > 0 ? min(1, dt / DS.Motion.quick) : 1
        level += (target - level) * CGFloat(k)
        return level
    }
}
