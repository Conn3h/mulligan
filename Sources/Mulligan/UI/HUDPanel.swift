import AppKit
import SwiftUI

/// The floating "quiet instrument" HUD (spec §6.14). A borderless, non-activating `NSPanel`
/// that shows live dictation state above whatever the user is typing into without ever
/// taking focus from it — invariant 1 (§4): if the HUD became key, the field the user was
/// dictating into would lose focus and there would be nothing left to insert into.
@MainActor
final class HUDPanel: NSPanel {
    private let hostingView: NSHostingView<HUDView>

    init(controller: DictationController) {
        hostingView = NSHostingView(rootView: HUDView(controller: controller))
        let size = NSSize(width: DS.Metric.hudWidth, height: DS.Metric.hudHeight)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        contentView = hostingView
        alphaValue = 0
    }

    /// The HUD never becomes key or main (invariant 1). Do not change these.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Repositions to the bottom-centre of the key window's screen (first screen as a
    /// fallback) and fades in over `DS.Motion.hud`. A no-op when the HUD is already fully
    /// visible, so the rapid `.starting` -> `.listening` -> `.finishing` transitions within
    /// one utterance never restart the fade and flicker.
    func present() {
        if isVisible, alphaValue >= 1 {
            return
        }
        reposition()
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.hud
            animator().alphaValue = 1
        }
    }

    /// Fades out over `DS.Motion.hud` and orders out on completion. Guards against a stale
    /// completion: if `present()` fades the HUD back in before this animation's handler
    /// runs, the handler must not order out a panel that is visible again.
    func dismiss() {
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = DS.Motion.hud
                animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.alphaValue == 0 else {
                        return
                    }
                    self.orderOut(nil)
                }
            }
        )
    }

    private func reposition() {
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.screens.first else {
            Log.app.error("HUD reposition skipped: no screen available")
            return
        }
        let visible = screen.visibleFrame
        setFrameOrigin(
            NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.minY + DS.Metric.hudBottomOffset
            )
        )
    }
}
