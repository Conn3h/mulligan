import AppKit
import SwiftUI

/// The single source of every visual constant in Mulligan: the "quiet instrument" design
/// direction from spec §6.14 as Swift values. Views must never contain a literal colour,
/// size, radius, font or duration — every such value is a token here. If a component needs
/// a value that has no token yet, add one to the appropriate namespace below; never rename
/// or remove a token another batch may already depend on.
///
/// Two rules are encoded by these tokens but not enforced by the compiler, so state them
/// where every consumer will read them:
///
/// 1. **`Color.accent` means "recording", and nothing else.** It is a muted coral red used
///    for the recording lamp, the mic-active affordance, and the HUD's error text. It must
///    never be used for a button, a link, a selection highlight, or any other kind of
///    emphasis.
/// 2. **`Color.meterLow` and `Color.meterHigh` are level-meter colours only.** The
///    restrained green-to-amber scale they form appears nowhere else in the chrome; using
///    either colour outside a level meter would make the meter's own coding ambiguous.
///
/// No gradients anywhere: every colour token below is a flat fill. Depth comes from
/// `Color.panel` / `Color.panelRaised` fills and `Color.hairline` borders, not shading.
enum DS {}

// MARK: - Color

extension DS {
    /// Flat, appearance-adaptive fills and ink colours. Light appearance is warm off-white
    /// panels on a slightly darker warm ground with near-black ink; dark appearance is warm
    /// charcoal panels one clear step above a near-black ground, with off-white ink (the
    /// design lift, spec v1.5, raised the dark values so panels no longer vanish into black). Every colour resolves per the
    /// current `NSAppearance`, so a single value works in both.
    enum Color {
        /// The window/screen backdrop behind every panel.
        static let ground = adaptiveColor("DS.ground", light: 0xE9E5DD, dark: 0x0E0D0C)
        /// The standard surface fill for cards, rows and controls.
        static let panel = adaptiveColor("DS.panel", light: 0xF6F3EC, dark: 0x1A1917)
        /// A slightly lighter surface for content that should read as sitting above
        /// `panel`, e.g. a hovered row or an inline field.
        static let panelRaised = adaptiveColor("DS.panelRaised", light: 0xFCFAF4, dark: 0x262420)

        /// Primary text and iconography.
        static let ink = adaptiveColor("DS.ink", light: 0x1C1B18, dark: 0xEDEAE3)
        /// Secondary text: captions under a headline, metadata in a list row.
        static let inkSecondary = adaptiveColor("DS.inkSecondary", light: 0x5C594E, dark: 0xB0AB9F)
        /// Tertiary text and disabled iconography: the least emphasis before invisible.
        static let inkTertiary = adaptiveColor("DS.inkTertiary", light: 0x8B8778, dark: 0x7D7A70)

        /// Low-contrast borders that separate panels without drawing attention to
        /// themselves.
        static let hairline = adaptiveColor("DS.hairline", light: 0xDAD5C9, dark: 0x2E2C27)

        /// "Recording", and nothing else. See rule 1 on `DS`.
        static let accent = adaptiveColor("DS.accent", light: 0xD8584A, dark: 0xE06A5C)

        /// Level-meter low end. Meter colours only; see rule 2 on `DS`.
        static let meterLow = adaptiveColor("DS.meterLow", light: 0x5F8F63, dark: 0x6FA173)
        /// Level-meter high end. Meter colours only; see rule 2 on `DS`.
        static let meterHigh = adaptiveColor("DS.meterHigh", light: 0xC99A3B, dark: 0xD9AC4D)

        /// A subtle tint of `ink`, for selected rows and highlighted text ranges.
        static let selection = adaptiveColor(
            "DS.selection", light: 0x1C1B18, dark: 0xEDEAE3, lightAlpha: 0.08, darkAlpha: 0.10
        )

        // Not named in §6.14; added by fix batch 1 (agent S1) so views never reach for the
        // bare SwiftUI literal. Transparent has no appearance-dependent component, so this
        // is a plain alias rather than an `adaptiveColor` call.
        /// Fully transparent fill, for the unselected state of a control that otherwise
        /// paints `selection`.
        static let clear = SwiftUI.Color.clear

        // Not named in §6.14; added by the visual glow-up pass (still "quiet instrument",
        // §6.14). Constant across appearance: both `accent` variants below are mid-toned
        // enough that a fixed warm off-white reads clearly on either.
        /// Text and iconography drawn on top of a filled `accent` surface, e.g. the Record
        /// key's label while recording. Never used on any other fill.
        static let inkOnAccent = adaptiveColor("DS.inkOnAccent", light: 0xFAF7F0, dark: 0xFAF7F0)

        /// A slightly deeper well than `panel`, for the History/Dictionary content area: the
        /// masthead and its tabs sit on `ground`, the switched content recedes one step
        /// further so the two rows scanned most often (masthead, list) read as distinct
        /// planes without a shadow.
        static let panelSunken = adaptiveColor("DS.panelSunken", light: 0xF0EDE5, dark: 0x0F0E0D)

        /// A more visible hairline than the default, for the one boundary that must read as
        /// a deliberate edge rather than a seam: the masthead's bottom rule, now that the
        /// window is one matte plate under a hidden title bar.
        static let hairlineStrong = adaptiveColor("DS.hairlineStrong", light: 0xC7BFAE, dark: 0x3D3A34)
    }
}

/// Builds a `SwiftUI.Color` that resolves `light` under aqua appearance and `dark` under
/// dark appearance, per §6.14's mandate to adapt colours via
/// `Color(nsColor: NSColor(name:dynamicProvider:))` rather than a static asset-catalogue
/// colour. Recomputed on each access (no cached static state), which keeps every `DS.Color`
/// token a plain, uncached `Sendable` value.
private func adaptiveColor(
    _ name: String,
    light: UInt32,
    dark: UInt32,
    lightAlpha: CGFloat = 1,
    darkAlpha: CGFloat = 1
) -> SwiftUI.Color {
    let dynamic = NSColor(name: NSColor.Name(name)) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(hexValue: dark, alpha: darkAlpha)
            : NSColor(hexValue: light, alpha: lightAlpha)
    }
    return SwiftUI.Color(nsColor: dynamic)
}

private extension NSColor {
    /// Convenience for the hex literals in `DS.Color`. Not exposed outside this file; the
    /// rest of the app reaches colours only through `DS.Color`.
    convenience init(hexValue hex: UInt32, alpha: CGFloat) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Space

extension DS {
    /// Spacing scale, in points. Every padding, spacing and offset in the app comes from
    /// this ladder.
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 8
        static let base: CGFloat = 12
        static let roomy: CGFloat = 16
        static let wide: CGFloat = 24
        static let panel: CGFloat = 32

        // Not named in §6.14; added by fix batch 1 (agent S1) so `spacing: 0` /
        // `minLength: 0` sites read from the ladder like every other spacing value.
        /// Zero spacing: a stack that should have no gap between its children, or a
        /// `Spacer` with no enforced minimum.
        static let none: CGFloat = 0
    }
}

// MARK: - Radius

extension DS {
    /// Corner radii. Flat fills plus hairline borders give depth, not shadows.
    enum Radius {
        static let control: CGFloat = 6
        static let panel: CGFloat = 10
        static let hud: CGFloat = 22
    }
}

// MARK: - Font

extension DS {
    /// Type scale. All sizes are the system font; `readout` additionally fixes tabular
    /// (monospaced) digits and a slightly heavier weight, since it is the only token used
    /// for a live-updating counter, where digit widths must not jitter.
    enum Font {
        static let title = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        static let label = SwiftUI.Font.system(size: 12, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
        /// Tabular numerals, slightly heavier than `body`: elapsed-time and process-time
        /// counters.
        static let readout = SwiftUI.Font.system(size: 15, weight: .semibold).monospacedDigit()

        // Not named in §6.14; added by fix batch 1 (agent S1). A standalone SF Symbol glyph
        // (e.g. `EmptyStateView`'s centred icon) is sized on its own rather than inheriting a
        // text style, so it needs a constructor, not a fixed size like the tokens above.
        /// A `.system` icon font at `size`, for a glyph-only `Image(systemName:)` that must
        /// not inherit the surrounding text style.
        static func icon(size: CGFloat) -> SwiftUI.Font {
            .system(size: size)
        }

        // Not named in §6.14; added by the visual glow-up pass. Pair with
        // `.tracking(DS.Metric.eyebrowTracking)` at the call site — `Font` carries no
        // tracking of its own — and with the literal, already-uppercase word: this style is
        // reserved for the masthead's four status words (READY, LISTENING, TYPED, RECORDED)
        // and the dictionary's kind tag.
        /// 11 pt medium, meant to run uppercase and tracked.
        static let eyebrow = SwiftUI.Font.system(size: 11, weight: .medium)

        // Not named in §6.14; added by the visual glow-up pass for the masthead's elapsed
        // counter, the one number in the window meant to be read from across a room.
        /// Large tabular-digit readout: about 28 pt, regular weight, monospaced digits.
        static let readoutLarge = SwiftUI.Font.system(size: 28, weight: .regular).monospacedDigit()
    }
}

// MARK: - Border

extension DS {
    /// Line weights for strokes.
    enum Border {
        static let hairline: CGFloat = 1
    }
}

// MARK: - Motion

extension DS {
    /// Animation durations, in seconds. No motion in Mulligan reaches for a value outside
    /// this list.
    enum Motion {
        static let quick: Double = 0.12
        static let panel: Double = 0.2
        static let hud: Double = 0.16

        // Not named in §6.14; added by batch B2. The period, in seconds, of one ripple
        // cycle through the HUD's level meter bars.
        /// Seconds per ripple cycle for the HUD meter's phase animation.
        static let hudMeterCycle: Double = 0.9

        // Not named in §6.14; added by batch C1.
        /// Refresh interval, in seconds, for the main window's elapsed-time readout.
        static let elapsedTick: Double = 0.1
        /// Refresh interval, in seconds, for `SettingsWindow`'s permission-status poll.
        static let permissionPollInterval: Double = 1.0

        // Not named in §6.14; added by the visual glow-up pass.
        /// Seconds the masthead status eyebrow holds "TYPED …" / "RECORDED …" after an
        /// utterance before it reverts to "READY".
        static let statusHoldSeconds: Double = 4.0
        /// Seconds per idle-ripple cycle in the masthead's level meter. A separate token
        /// from `hudMeterCycle` even though the value matches, so each meter's owner can be
        /// retuned independently.
        static let mastheadMeterCycle: Double = 0.9
    }
}

// MARK: - Metric

extension DS {
    /// One-off numeric constants that are not spacing, radius, font or duration: window and
    /// HUD dimensions, bar counts, and similar layout facts named in §6.14.
    enum Metric {
        static let hudWidth: CGFloat = 340
        static let hudHeight: CGFloat = 76
        static let hudBottomOffset: CGFloat = 96
        static let hudBarCount: Int = 12
        static let hudBarFloor: CGFloat = 3
        static let hudBarWidth: CGFloat = 3
        static let hudBarSpacing: CGFloat = 3
        static let meterBarCount: Int = 12
        static let windowDefaultWidth: CGFloat = 860
        static let windowDefaultHeight: CGFloat = 620
        static let windowMinWidth: CGFloat = 720
        static let windowMinHeight: CGFloat = 520
        static let copiedFeedbackSeconds: Double = 1.4

        // Not named in §6.14; added for TokenSheet's own layout per that section's
        // instruction to add a token rather than inline a number ("add the token, such as
        // DS.Metric.swatchSize"). Reported to the orchestrator alongside every other token.
        /// Side length of a colour swatch square in `TokenSheet`.
        static let swatchSize: CGFloat = 44
        /// Width of the name column in a `TokenSheet` row, wide enough for the longest
        /// token name in any section.
        static let tokenSheetLabelWidth: CGFloat = 132
        /// Height of the bar `TokenSheet` draws to visualise each `Space` value.
        static let tokenSheetBarHeight: CGFloat = 10

        // Not named in §6.14; added by batch B2 for the HUD's level meter.
        /// Peak height a HUD meter bar reaches at full level; bars rest at `hudBarFloor`
        /// between peaks and when the meter is inactive.
        static let hudBarMaxHeight: CGFloat = 22

        // Not named in §6.14; added by batch C1 for `Components.LevelMeterView`, the main
        // window's level meter. Deliberately separate from the HUD's own `hudBar*` tokens
        // (§6.14 already reserves plain `meterBarCount`, shared by both meters, for the bar
        // count) so the two meters can be tuned independently.
        /// Width of one bar in `LevelMeterView`.
        static let meterBarWidth: CGFloat = 4
        /// Spacing between bars in `LevelMeterView`.
        static let meterBarSpacing: CGFloat = 4
        /// Rest height of an unlit `LevelMeterView` bar.
        static let meterBarFloor: CGFloat = 4
        /// Height of a lit `LevelMeterView` bar.
        static let meterBarMaxHeight: CGFloat = 28

        // Not named in §6.14; added by batch C1.
        /// Diameter of the main window's recording lamp.
        static let lampSize: CGFloat = 10
        /// Minimum width of one option in `SegmentedChoice`, shared by the History/Dictionary
        /// tabs, the push-to-talk key picker and the dictionary kind toggle so every "keycap"
        /// in the app reads as one family.
        static let keycapMinWidth: CGFloat = 64
        /// Point size of the glyph in `EmptyStateView`.
        static let emptyStateIconSize: CGFloat = 32
        /// Opacity of a disabled dictionary entry's row, so a glance at the list shows which
        /// entries are off without needing to read every toggle.
        static let disabledEntryOpacity: Double = 0.5

        // Not named in §6.14; added by fix batch 1 (agent S1) for `HUDLabel`'s
        // `lineLimit(_:reservesSpace:)`.
        /// Number of lines the HUD's status label reserves, so the meter above it never
        /// shifts as the transcript wraps from one line to two.
        static let hudLineCount: Int = 2

        // Not named in §6.14; added by the visual glow-up pass for the main window's
        // masthead, the instrument's face (§6.14 direction: "quiet instrument").
        /// Bar count for the masthead's full-width level meter. Deliberately separate from
        /// `meterBarCount`, which no other view still uses after this pass, so a future
        /// batch can see at a glance which token belongs to which meter.
        static let mastheadBarCount: Int = 40
        /// Width of one bar in the masthead meter. Spacing is computed at layout time to
        /// fill the available width evenly, so there is no paired spacing token.
        static let mastheadBarWidth: CGFloat = 2
        /// Rest height of a masthead meter bar, whether idle or lit.
        static let mastheadBarFloor: CGFloat = 3
        /// Peak height a masthead meter bar reaches at full level.
        static let mastheadBarMaxHeight: CGFloat = 28
        /// Fraction (0...1) of the floor-to-peak range the idle ripple uses: "a faint idle
        /// ripple at very low amplitude," never mistaken for the meter actually reading a
        /// level.
        static let mastheadRippleAmplitude: Double = 0.18
        /// Scale factor applied to the Record key while pressed.
        static let pressedScale: CGFloat = 0.96
        /// Width of the fixed time-of-day column in a `HistoryRow`.
        static let historyTimeColumnWidth: CGFloat = 56
        /// Width of the fixed kind-tag column ("term" / "fix") in a `DictionaryRow`.
        static let dictionaryKindTagWidth: CGFloat = 40
        /// Letter-spacing for `DS.Font.eyebrow`, about 0.08 em at that font's 11 pt size.
        /// `Font` carries no tracking of its own, so this pairs with it via
        /// `.tracking(DS.Metric.eyebrowTracking)` at each call site.
        static let eyebrowTracking: CGFloat = 0.9

        // Added by the design lift (spec v1.5): the main window's status header, which sits
        // in the hidden title bar beside the window controls.
        /// Height of the status header: the title bar band, so its controls sit on the same
        /// centre line as the close, minimise and zoom buttons (measured on macOS 26).
        static let headerHeight: CGFloat = 32
        /// Space between the header band and the panel below it.
        static let headerGap: CGFloat = 10
        /// Leading room left for the close, minimise and zoom buttons.
        static let windowControlsClearance: CGFloat = 78
        /// Diameter of the header's status dot.
        static let statusDotSize: CGFloat = 8
        /// Side of a square icon button: the header's Record and Settings buttons.
        static let iconButtonSize: CGFloat = 28
        /// Side of a History row's copy and delete buttons.
        static let rowButtonSize: CGFloat = 24
        /// Width of the Settings window's grouped form.
        static let settingsWidth: CGFloat = 480
        /// Width of the first-run welcome sheet.
        static let welcomeWidth: CGFloat = 440
        /// Size of the tee-shot glyph in the welcome sheet.
        static let welcomeGlyphHeight: CGFloat = 72
    }
}

// MARK: - Tee shot

extension DS {
    /// The tee-shot mark (spec v1.5): a ball on a tee with sound arcs coming off it. The app
    /// icon draws it, and the HUD uses it as its lamp and level meter: the ball is the
    /// recording lamp, the arcs light outward with level in the meter colours. Geometry is
    /// in a `width` x `height` box and scales with it.
    enum TeeShot {
        static let width: CGFloat = 46
        static let height: CGFloat = 60
        static let ballCentre = CGPoint(x: 16, y: 28)
        static let ballRadius: CGFloat = 8
        /// The tee's cup: top-left, top-right, bottom-right, bottom-left.
        static let cup: [CGPoint] = [CGPoint(x: 9, y: 37), CGPoint(x: 23, y: 37), CGPoint(x: 19.5, y: 41), CGPoint(x: 12.5, y: 41)]
        static let stem = CGRect(x: 14.6, y: 40, width: 2.8, height: 13)
        /// Arc radii from the ball's centre, inner to outer. The meter lights them in order.
        static let arcRadii: [CGFloat] = [12, 17, 22, 27, 32]
        /// Half the angle each arc spans, either side of horizontal.
        static let arcHalfAngleDegrees: Double = 40
        static let arcLineWidth: CGFloat = 2.2
    }
}

// MARK: - Material

extension DS {
    /// System materials. Added by batch B2: §6.14 calls for "the HUD's material background"
    /// as the one deliberate exception to "no blur-heavy glass"; every other surface in the
    /// app is a flat `DS.Color` fill. Kept here, not inlined in `HUDView`, for the same
    /// reason every other visual constant lives in `DS`.
    enum Material {
        static let hud: SwiftUI.Material = .regularMaterial
    }
}
