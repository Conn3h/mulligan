import SwiftUI

/// The HUD's content (spec §6.14): a rippling level meter on the left, a coral lamp dot that
/// lights only while listening, then the two-line status text — all in one row, on a
/// material card. Hosted by `HUDPanel` via `NSHostingView`.
struct HUDView: View {
    let controller: DictationController

    var body: some View {
        HStack(spacing: DS.Space.base) {
            HUDMeterView(level: controller.level, isActive: controller.state.isActive)

            if case .listening = controller.state {
                Circle()
                    .fill(DS.Color.accent)
                    .frame(width: DS.Metric.lampSize, height: DS.Metric.lampSize)
                    .accessibilityHidden(true)
            }

            HUDLabel(state: controller.state, transcript: controller.transcript)
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.snug)
        .frame(width: DS.Metric.hudWidth, height: DS.Metric.hudHeight)
        .background(DS.Material.hud, in: RoundedRectangle(cornerRadius: DS.Radius.hud))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.hud)
                .strokeBorder(DS.Color.hairline, lineWidth: DS.Border.hairline)
        )
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

/// A `DS.Metric.hudBarCount`-bar level meter. Each bar has a fixed phase offset so the group
/// ripples as a wave rather than pumping in lockstep; bars rest at `DS.Metric.hudBarFloor`
/// when the meter is inactive or silent.
private struct HUDMeterView: View {
    let level: Float
    let isActive: Bool

    /// A plain reference type the view holds (via `@State`, for stable identity across
    /// re-renders — the object itself is never reassigned). Its `advance(to:)` mutates a
    /// plain stored property, not a `@State` value, so calling it from inside the
    /// `TimelineView` draw closure below is safe: spec §10 warns that mutating an actual
    /// `@State` value from a `TimelineView`/`Canvas` draw closure floods the log, but plain
    /// property mutation on a held object never goes through SwiftUI's state machinery.
    @State private var clock = HUDMeterClock()

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { context in
            let elapsed = clock.advance(to: context.date)
            HStack(spacing: DS.Metric.hudBarSpacing) {
                ForEach(0..<DS.Metric.hudBarCount, id: \.self) { index in
                    bar(index: index, elapsed: elapsed)
                }
            }
        }
        .frame(height: DS.Metric.hudBarMaxHeight)
    }

    private func bar(index: Int, elapsed: TimeInterval) -> some View {
        let fraction = wave(index: index, elapsed: elapsed)
        return Capsule()
            .fill(DS.Color.meterLow.mix(with: DS.Color.meterHigh, by: Double(fraction)))
            .frame(width: DS.Metric.hudBarWidth, height: height(fraction: fraction))
    }

    /// 0...1 position in this bar's ripple, offset from every other bar by its index so the
    /// peak travels across the row instead of every bar rising together.
    private func wave(index: Int, elapsed: TimeInterval) -> CGFloat {
        guard isActive, level > 0 else {
            return 0
        }
        let phaseOffset = Double(index) / Double(DS.Metric.hudBarCount) * (2 * .pi)
        let cyclePosition = elapsed / DS.Motion.hudMeterCycle * (2 * .pi)
        return CGFloat((sin(cyclePosition + phaseOffset) + 1) / 2)
    }

    private func height(fraction: CGFloat) -> CGFloat {
        let amplitude = CGFloat(level) * (DS.Metric.hudBarMaxHeight - DS.Metric.hudBarFloor)
        return DS.Metric.hudBarFloor + amplitude * fraction
    }
}

/// See `HUDMeterView`'s doc comment: physics live here, not in `@State`, so the
/// `TimelineView` draw closure can update it every frame without flooding the log.
@MainActor
private final class HUDMeterClock {
    private var last: Date?
    private(set) var elapsed: TimeInterval = 0

    @discardableResult
    func advance(to date: Date) -> TimeInterval {
        if let last {
            elapsed += date.timeIntervalSince(last)
        }
        last = date
        return elapsed
    }
}
