import AppKit
import Testing
@testable import Mulligan

/// Constructs an `HUDPanel` directly — no window server session or Accessibility grant is
/// needed to instantiate an `NSPanel` in a test process — and asserts every configuration
/// invariant demanded by spec §6.14 and invariant 1 (§4): the HUD never becomes key or
/// main, is borderless and non-activating, floats at status-bar level, joins every space
/// including full-screen apps and stays put across a Spaces switch, stays visible when the
/// app deactivates, ignores the mouse entirely, and is sized exactly from `DS.Metric`.
@MainActor
struct HUDPanelTests {
    private func makePanel() -> HUDPanel {
        HUDPanel(controller: Harness().controller)
    }

    @Test func neverBecomesKeyOrMain() {
        let panel = makePanel()
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
    }

    @Test func styleMaskIsBorderlessAndNonactivating() {
        let panel = makePanel()
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
    }

    @Test func floatsAtStatusBarLevel() {
        let panel = makePanel()
        #expect(panel.level == .statusBar)
    }

    @Test func collectionBehaviorSpansSpacesAndFullScreenAndStaysPut() {
        let panel = makePanel()
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.stationary))
    }

    @Test func staysVisibleWhenTheAppDeactivates() {
        let panel = makePanel()
        #expect(panel.hidesOnDeactivate == false)
    }

    @Test func ignoresTheMouse() {
        let panel = makePanel()
        #expect(panel.ignoresMouseEvents == true)
    }

    @Test func sizedExactlyFromDesignTokens() {
        let panel = makePanel()
        #expect(panel.frame.size.width == DS.Metric.hudWidth)
        #expect(panel.frame.size.height == DS.Metric.hudHeight)
    }
}
