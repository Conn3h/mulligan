import SwiftUI

/// Visual reference for every token in `DS`, laid out so a person can eyeball the "quiet
/// instrument" system — contrast, rhythm, and the reserved colours — in both light and dark
/// appearance before other views start consuming these tokens. Every value this view uses
/// for its own layout is itself a `DS` token; where no token named in spec §6.14 fit, one
/// was added to `DS.Metric` (see that file's comment) rather than inlining a number here.
struct TokenSheet: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.wide) {
                section(title: "Color") {
                    VStack(alignment: .leading, spacing: DS.Space.snug) {
                        ForEach(Self.colorTokens, id: \.name) { token in
                            colorRow(token)
                        }
                    }
                }
                section(title: "Font") {
                    VStack(alignment: .leading, spacing: DS.Space.base) {
                        ForEach(Self.fontTokens, id: \.name) { token in
                            fontRow(token)
                        }
                    }
                }
                section(title: "Space") {
                    VStack(alignment: .leading, spacing: DS.Space.snug) {
                        ForEach(Self.spaceTokens, id: \.name) { token in
                            spaceRow(token)
                        }
                    }
                }
            }
            .padding(DS.Space.panel)
        }
        .background(DS.Color.ground)
    }

    // MARK: Rows

    private func colorRow(_ token: ColorToken) -> some View {
        HStack(spacing: DS.Space.base) {
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(token.color)
                .frame(width: DS.Metric.swatchSize, height: DS.Metric.swatchSize)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .stroke(DS.Color.hairline, lineWidth: DS.Border.hairline)
                )
            Text(token.name)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
        }
    }

    private func fontRow(_ token: FontToken) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.base) {
            Text(token.name)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .frame(width: DS.Metric.tokenSheetLabelWidth, alignment: .leading)
            Text(token.sample)
                .font(token.font)
                .foregroundStyle(DS.Color.ink)
        }
    }

    private func spaceRow(_ token: SpaceToken) -> some View {
        HStack(spacing: DS.Space.base) {
            Text(token.name)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .frame(width: DS.Metric.tokenSheetLabelWidth, alignment: .leading)
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(DS.Color.inkTertiary)
                .frame(width: token.value, height: DS.Metric.tokenSheetBarHeight)
            Text(token.pointsLabel)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkTertiary)
        }
    }

    // MARK: Section chrome

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Text(title)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
            content()
        }
        .padding(DS.Space.roomy)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .fill(DS.Color.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .stroke(DS.Color.hairline, lineWidth: DS.Border.hairline)
        )
    }
}

// MARK: - Token catalogues

extension TokenSheet {
    fileprivate struct ColorToken {
        let name: String
        let color: SwiftUI.Color
    }

    fileprivate struct FontToken {
        let name: String
        let font: SwiftUI.Font
        let sample: String
    }

    fileprivate struct SpaceToken {
        let name: String
        let value: CGFloat
        var pointsLabel: String { "\(Int(value)) pt" }
    }

    fileprivate static let colorTokens: [ColorToken] = [
        ColorToken(name: "ground", color: DS.Color.ground),
        ColorToken(name: "panel", color: DS.Color.panel),
        ColorToken(name: "panelRaised", color: DS.Color.panelRaised),
        ColorToken(name: "ink", color: DS.Color.ink),
        ColorToken(name: "inkSecondary", color: DS.Color.inkSecondary),
        ColorToken(name: "inkTertiary", color: DS.Color.inkTertiary),
        ColorToken(name: "hairline", color: DS.Color.hairline),
        ColorToken(name: "accent (recording only)", color: DS.Color.accent),
        ColorToken(name: "meterLow (meters only)", color: DS.Color.meterLow),
        ColorToken(name: "meterHigh (meters only)", color: DS.Color.meterHigh),
        ColorToken(name: "selection", color: DS.Color.selection),
    ]

    fileprivate static let fontTokens: [FontToken] = [
        FontToken(name: "title", font: DS.Font.title, sample: "Mulligan"),
        FontToken(name: "body", font: DS.Font.body, sample: "The quiet instrument, at rest."),
        FontToken(name: "label", font: DS.Font.label, sample: "PUSH TO TALK"),
        FontToken(name: "caption", font: DS.Font.caption, sample: "Recordings started here are saved to History."),
        FontToken(name: "readout", font: DS.Font.readout, sample: "00:12.4"),
    ]

    fileprivate static let spaceTokens: [SpaceToken] = [
        SpaceToken(name: "hair", value: DS.Space.hair),
        SpaceToken(name: "tight", value: DS.Space.tight),
        SpaceToken(name: "snug", value: DS.Space.snug),
        SpaceToken(name: "base", value: DS.Space.base),
        SpaceToken(name: "roomy", value: DS.Space.roomy),
        SpaceToken(name: "wide", value: DS.Space.wide),
        SpaceToken(name: "panel", value: DS.Space.panel),
    ]
}

#Preview {
    TokenSheet()
        .frame(width: DS.Metric.windowDefaultWidth, height: DS.Metric.windowDefaultHeight)
}
