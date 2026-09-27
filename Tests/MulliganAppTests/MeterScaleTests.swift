import Testing
@testable import Mulligan

/// The HUD meter's display curve: measured speech peaks at about 0.3 to 0.45 (2026-09-28
/// logs), so the arcs must reach the outer ones well before a level of 1.
@Suite
struct MeterScaleTests {
    @Test func silenceStaysDark() {
        #expect(MeterScale.display(0) == 0)
    }

    @Test func aTypicalSpeechPeakFillsTheMeter() {
        #expect(MeterScale.display(0.45) == 1)
        #expect(MeterScale.display(0.9) == 1)
    }

    @Test func ordinarySpeechReachesTheMiddleArcs() {
        // A level of 0.2 must light more than two of the five arcs.
        #expect(MeterScale.display(0.2) * 5 > 2.5)
    }

    @Test func louderIsNeverDimmer() {
        let levels: [Float] = [0, 0.02, 0.05, 0.1, 0.2, 0.3, 0.45, 1]
        let shown = levels.map { MeterScale.display($0) }
        #expect(shown == shown.sorted())
    }

    @Test func outOfRangeIsClamped() {
        #expect(MeterScale.display(-1) == 0)
    }
}
