import SwiftUI

/// Shared pieces for the app shell, built on top of `DS` (spec §6.14).

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
    /// The recessed track behind the pills: `ground` inside a panel, `panel` on the ground.
    var track: SwiftUI.Color = DS.Color.ground
    // Declared last so a trailing closure binds to it at call sites that omit `track`.
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: DS.Space.hair) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(DS.Space.hair)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(track))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .stroke(DS.Color.hairline, lineWidth: DS.Border.hairline)
        )
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
                .padding(.vertical, DS.Space.tight)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .fill(isSelected ? DS.Color.selection : DS.Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .stroke(isSelected ? DS.Color.hairline : DS.Color.clear, lineWidth: DS.Border.hairline)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Keycap

/// A key name drawn as a small keycap ("Right ⌥"), for hints that teach the keys.
@MainActor
struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.ink)
            .padding(.horizontal, DS.Space.tight + DS.Space.hair)
            .padding(.vertical, DS.Space.hair)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control - DS.Space.hair).fill(DS.Color.panelRaised))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control - DS.Space.hair)
                    .stroke(DS.Color.hairlineStrong, lineWidth: DS.Border.hairline)
            )
    }
}

// MARK: - Icon button

/// A square, hairline-bordered button holding one SF Symbol: the header's Record and
/// Settings buttons. `filled` paints it with `fill` (the Record button while recording).
@MainActor
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = DS.Metric.iconButtonSize
    var filled: SwiftUI.Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.label)
            .foregroundStyle(filled == nil ? DS.Color.inkSecondary : DS.Color.inkOnAccent)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(filled ?? (configuration.isPressed ? DS.Color.panelRaised : DS.Color.panel))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .stroke(filled == nil ? DS.Color.hairline : DS.Color.clear, lineWidth: DS.Border.hairline)
            )
            .scaleEffect(configuration.isPressed ? DS.Metric.pressedScale : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Motion.quick), value: configuration.isPressed)
            .contentShape(Rectangle())
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

/// The surface under the header that holds History or Dictionary: `panel`, one step above
/// the window's ground (the design lift, spec v1.5, raised it from the old sunken well),
/// clipped to `DS.Radius.panel` so the search field and footer inside sit flush with the
/// rounded corners, with a hairline border for the edge. Unlike `Panel`, this adds no
/// internal padding — the panel it hosts already paces its own edges (search field, rows,
/// footer), which need to run flush to draw full-width hairlines and hover fills.
@MainActor
struct ContentWell<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(DS.Color.panel)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.panel)
                    .stroke(DS.Color.hairline, lineWidth: DS.Border.hairline)
            )
    }
}
