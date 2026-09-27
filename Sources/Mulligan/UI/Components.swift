import SwiftUI

/// Shared pieces for the C1 app shell, built fresh on top of `DS` (spec §6.14). Nothing here
/// reads `HUDView`'s private types — that view's meter is HUD-only, so `LevelMeterView`
/// below is a separate implementation sharing only its design tokens.

// MARK: - Panel

/// A flat surface with a hairline border: the container every card, section and row group
/// in the app shell sits on.
@MainActor
struct Panel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(DS.Space.roomy)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Color.panel))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.panel)
                    .stroke(DS.Color.hairline, lineWidth: DS.Border.hairline)
            )
    }
}

// MARK: - Section header

/// A quiet, uppercase label that introduces a group of controls.
@MainActor
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(DS.Font.label)
            .foregroundStyle(DS.Color.inkSecondary)
    }
}

// MARK: - Search field

/// A single-line search box with a leading glyph and a clear button, styled as an inset
/// field rather than the system search field so it matches the rest of the chrome.
@MainActor
struct SearchField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DS.Color.inkTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Color.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.panelRaised))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .stroke(DS.Color.hairline, lineWidth: DS.Border.hairline)
        )
    }
}

// MARK: - Chip

/// A small rounded badge for metadata: engine names, source labels, correction summaries.
@MainActor
struct Chip<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.inkSecondary)
            .padding(.horizontal, DS.Space.snug)
            .padding(.vertical, DS.Space.hair)
            .background(Capsule().fill(DS.Color.panelRaised))
            .overlay(Capsule().stroke(DS.Color.hairline, lineWidth: DS.Border.hairline))
    }
}

// MARK: - Empty state

/// A centred glyph and two lines of text for a panel with nothing in it yet.
@MainActor
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: DS.Space.snug) {
            Image(systemName: systemImage)
                .font(DS.Font.icon(size: DS.Metric.emptyStateIconSize))
                .foregroundStyle(DS.Color.inkTertiary)
            Text(title)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
            Text(message)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.panel)
    }
}

// MARK: - Segmented choice

/// A keycap-style segmented control: flat pills in a recessed track, sharing one visual
/// family across every exclusive choice in the app shell — the History/Dictionary tabs, the
/// push-to-talk key picker, and the dictionary entry kind toggle. Selection uses
/// `DS.Color.selection`, the token spec §6.14 reserves for "selected rows and highlighted
/// text ranges."
@MainActor
struct SegmentedChoice<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: DS.Space.hair) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(DS.Space.hair)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.ground))
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option == selection
        return Button {
            selection = option
        } label: {
            Text(label(option))
                .font(DS.Font.label)
                .foregroundStyle(isSelected ? DS.Color.ink : DS.Color.inkSecondary)
                .frame(minWidth: DS.Metric.keycapMinWidth)
                .padding(.horizontal, DS.Space.base)
                .padding(.vertical, DS.Space.snug)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .fill(isSelected ? DS.Color.selection : DS.Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .stroke(isSelected ? DS.Color.hairline : DS.Color.clear, lineWidth: DS.Border.hairline)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Masthead meter

/// Whether the masthead meter should run its per-frame `TimelineView`. Pure so the gate is
/// tested without a host. Off whenever the window's pixels are not on screen (dictating into
/// another app, minimised, covered): the level still updates, the meter just stops
/// repainting. At rest the ripple is decoration, so reduce-motion turns it off; while
/// recording the meter must track level even with reduce motion, so only visibility gates it.
enum MeterAnimation {
    static func shouldAnimate(isActive: Bool, reduceMotion: Bool, windowVisible: Bool) -> Bool {
        guard windowVisible else { return false }
        return isActive || !reduceMotion
    }
}

/// The masthead's level meter, the window's signature element (§6.14 direction: "quiet
/// instrument"): `DS.Metric.mastheadBarCount` thin bars spanning the full width offered to
/// them. Two behaviours, chosen by `isActive`:
///
/// - **Recording**: bars light from `DS.Color.meterLow` to `DS.Color.meterHigh` as `level`
///   climbs, like a classic VU ladder — a fresh implementation, sharing only its tokens with
///   the HUD's own rippling meter (whose views are private to `HUDView`).
/// - **At rest**: a faint idle ripple travels through the bars at
///   `DS.Metric.mastheadRippleAmplitude` of the floor-to-peak range, in the neutral
///   `DS.Color.inkTertiary` rather than the meter gradient — reserving the green-to-amber
///   scale for an actual reading, per the rule that those colours mean something.
///   `reduceMotion` turns the ripple off; the bars then simply rest at the floor.
@MainActor
struct MastheadMeterView: View {
    let level: Float
    let isActive: Bool
    let reduceMotion: Bool
    let windowVisible: Bool

    @State private var clock = MastheadRippleClock()

    var body: some View {
        let animate = MeterAnimation.shouldAnimate(
            isActive: isActive, reduceMotion: reduceMotion, windowVisible: windowVisible
        )
        // A Canvas repaints on each tick WITHOUT a layout pass; the previous HStack of
        // capsules forced a full NSHostingView.layout() every frame (spec trap: keep
        // per-frame work off the layout engine). Paused (hidden, or idle + reduce motion)
        // the TimelineView renders once with the clock's held values: a single static draw.
        TimelineView(.animation(paused: !animate)) { context in
            let target = CGFloat(max(0, min(1, level)))
            let tick = animate
                ? clock.advance(to: context.date, toward: target)
                : (elapsed: clock.elapsed, level: clock.level)
            Canvas { gc, size in
                draw(into: gc, size: size, elapsed: tick.elapsed, level: tick.level)
            }
        }
        .frame(height: DS.Metric.mastheadBarMaxHeight)
    }

    private func draw(into gc: GraphicsContext, size: CGSize, elapsed: TimeInterval, level: CGFloat) {
        let barCount = DS.Metric.mastheadBarCount
        let spacing = spacing(for: size.width, barCount: barCount)
        let barWidth = DS.Metric.mastheadBarWidth
        let lit = litCount(for: level)
        for index in 0..<barCount {
            let x = CGFloat(index) * (barWidth + spacing)
            let height = barHeight(index: index, elapsed: elapsed, lit: lit)
            let rect = CGRect(x: x, y: size.height - height, width: barWidth, height: height)
            gc.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(barColor(index: index, lit: lit)))
        }
    }

    private func barHeight(index: Int, elapsed: TimeInterval, lit: Int) -> CGFloat {
        if isActive {
            return index < lit ? DS.Metric.mastheadBarMaxHeight : DS.Metric.mastheadBarFloor
        }
        if reduceMotion {
            return DS.Metric.mastheadBarFloor
        }
        return rippleHeight(index: index, elapsed: elapsed)
    }

    private func barColor(index: Int, lit: Int) -> SwiftUI.Color {
        guard isActive else { return DS.Color.inkTertiary }
        guard index < lit else { return DS.Color.hairline }
        let lastIndex = DS.Metric.mastheadBarCount - 1
        let position = lastIndex > 0 ? Double(index) / Double(lastIndex) : 0
        return DS.Color.meterLow.mix(with: DS.Color.meterHigh, by: position)
    }

    private func litCount(for level: CGFloat) -> Int {
        let clamped = max(0, min(1, level))
        return Int((clamped * CGFloat(DS.Metric.mastheadBarCount)).rounded())
    }

    private func spacing(for width: CGFloat, barCount: Int) -> CGFloat {
        let totalBarWidth = CGFloat(barCount) * DS.Metric.mastheadBarWidth
        let gapCount = max(barCount - 1, 1)
        return max(DS.Space.hair, (width - totalBarWidth) / CGFloat(gapCount))
    }

    /// Mirrors `HUDMeterView.wave(index:elapsed:)`: each bar's ripple is offset from every
    /// other by its index, so the peak travels across the row instead of every bar rising
    /// together.
    private func rippleHeight(index: Int, elapsed: TimeInterval) -> CGFloat {
        let phaseOffset = Double(index) / Double(DS.Metric.mastheadBarCount) * (2 * .pi)
        let cyclePosition = elapsed / DS.Motion.mastheadMeterCycle * (2 * .pi)
        let fraction = CGFloat((sin(cyclePosition + phaseOffset) + 1) / 2)
        let amplitude = CGFloat(DS.Metric.mastheadRippleAmplitude)
            * (DS.Metric.mastheadBarMaxHeight - DS.Metric.mastheadBarFloor)
        return DS.Metric.mastheadBarFloor + amplitude * fraction
    }
}

/// A plain reference type held via `@State` for stable identity across re-renders (never
/// reassigned). `advance(to:toward:)` mutates plain stored properties, not a `@State` value,
/// so calling it from the `TimelineView` draw closure above is safe — see `HUDMeterClock`'s
/// doc comment in `HUDView.swift` for why an actual `@State` mutation there would flood the
/// log.
@MainActor
private final class MastheadRippleClock {
    private var last: Date?
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: CGFloat = 0

    /// Advances ripple time and eases the displayed level toward `target`. `dt / quick`
    /// gives roughly the same settling time the old `.animation(.easeOut(quick))` did.
    @discardableResult
    func advance(to date: Date, toward target: CGFloat) -> (elapsed: TimeInterval, level: CGFloat) {
        let dt = last.map { date.timeIntervalSince($0) } ?? 0
        last = date
        elapsed += dt
        let k = DS.Motion.quick > 0 ? min(1, dt / DS.Motion.quick) : 1
        level += (target - level) * CGFloat(k)
        return (elapsed, level)
    }
}

// MARK: - Text tabs

/// A left-aligned row of quiet text choices with a hairline underline marking the selected
/// one — not a keycap track. Used for the History/Dictionary switch and, at `.small`, the
/// dictionary entry's kind switch. `SegmentedChoice` remains the keycap style for Settings'
/// push-to-talk picker, the one place §6.14 keeps it.
@MainActor
struct TextTabs<Option: Hashable>: View {
    enum Size {
        case regular
        case small
    }

    let options: [Option]
    @Binding var selection: Option
    var size: Size = .regular
    var count: ((Option) -> Int?)?
    // Declared last (after the defaulted `count`) so a single trailing closure at a call
    // site that omits `count` still unambiguously binds to this parameter.
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: DS.Space.wide) {
            ForEach(options, id: \.self) { option in
                tab(option)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tab(_ option: Option) -> some View {
        let isSelected = option == selection
        return Button {
            selection = option
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                HStack(spacing: DS.Space.tight) {
                    Text(label(option))
                        .font(font)
                        .foregroundStyle(isSelected ? DS.Color.ink : DS.Color.inkSecondary)
                    if let value = count?(option) {
                        Text("\(value)")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.inkTertiary)
                    }
                }
                Rectangle()
                    .fill(isSelected ? DS.Color.ink : DS.Color.clear)
                    .frame(height: DS.Border.hairline)
            }
            // A bare Rectangle is greedy; without this the underline runs to the edge
            // of whatever width the row hands out instead of hugging the label.
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }

    private var font: SwiftUI.Font {
        size == .regular ? DS.Font.label : DS.Font.caption
    }
}

// MARK: - Content well

/// The recessed surface under the tabs that holds History or Dictionary: `panelSunken`,
/// clipped to `DS.Radius.panel` so the search field and footer inside sit flush with the
/// rounded corners, with a hairline border for the edge. Unlike `Panel`, this adds no
/// internal padding — the panel it hosts already paces its own edges (search field, rows,
/// footer), which need to run flush to draw full-width hairlines and hover fills.
@MainActor
struct ContentWell<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(DS.Color.panelSunken)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.panel)
                    .stroke(DS.Color.hairline, lineWidth: DS.Border.hairline)
            )
    }
}
