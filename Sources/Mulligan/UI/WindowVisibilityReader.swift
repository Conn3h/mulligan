import AppKit
import SwiftUI

/// Reports whether the hosting window's pixels are actually on screen, via
/// `NSWindow.occlusionState` plus miniaturisation. Placed as a zero-size background of a
/// view; drives an idle animation gate so a covered or minimised window costs nothing.
/// AppKit occlusion has no SwiftUI environment key, so a tiny representable bridges it.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Main-actor isolated: `report()` and `onChange` touch main-actor-only state, and the
    /// notification block on macOS 26 is `@Sendable`, so the block hops here explicitly. This
    /// is a plain `Task { @MainActor }` hop, not `MainActor.assumeIsolated` (the one
    /// permitted `assumeIsolated` site stays the HotkeyMonitor C callback).
    @MainActor
    private final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        // `deinit` on an NSObject-derived class is never actor-isolated (Objective-C's
        // `dealloc` can run on any thread, so the compiler cannot infer MainActor isolation
        // there even though this class is `@MainActor`). Every actual mutation and read still
        // happens on the main actor (`viewDidMoveToWindow`) or in `deinit`, which by
        // construction cannot run concurrently with those (no other reference survives), so
        // there is no real race; `nonisolated(unsafe)` only lets `deinit` reach the array to
        // remove the observers.
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else {
                onChange?(false)
                return
            }
            let center = NotificationCenter.default
            for name: NSNotification.Name in [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ] {
                observers.append(
                    center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        Task { @MainActor in self?.report() }
                    }
                )
            }
            report()
        }

        private func report() {
            guard let window else {
                onChange?(false)
                return
            }
            let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized
            onChange?(visible)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
