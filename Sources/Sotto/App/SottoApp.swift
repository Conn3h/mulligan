import AppKit
import Observation
import SwiftUI

@main
struct SottoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        let controller = delegate.composition.controller

        Window("Sotto", id: "main") {
            MainWindow(controller: controller)
                .frame(minWidth: DS.Metric.windowMinWidth, minHeight: DS.Metric.windowMinHeight)
                .containerBackground(DS.Color.ground, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: DS.Metric.windowDefaultWidth, height: DS.Metric.windowDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Reveal Dictionary File") {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
                Button("Reload Dictionary") {
                    DictionaryStore.shared.reloadFromDisk()
                }
            }
        }

        MenuBarExtra(
            "Sotto",
            systemImage: controller.state.isActive ? "waveform.circle.fill" : "waveform"
        ) {
            MenuBarContent(controller: controller)
        }
        .menuBarExtraStyle(.menu)

        SwiftUI.Settings {
            SettingsWindow(controller: controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let accessibilityPollInterval: Duration = .seconds(1)

    let composition: AppComposition
    private var accessibilityPollTask: Task<Void, Never>?
    /// Batch B2. Created at launch, presented/dismissed as `controller.state.showsHUD`
    /// changes. Held here rather than on `AppComposition` because this batch owns only
    /// `SottoApp.swift`.
    private var hud: HUDPanel?

    override init() {
        composition = AppComposition()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The call reports false when nothing changed, which is the normal case here
        // (Info.plist already makes this a regular app), so only the end state matters.
        if NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
        }
        if NSApp.activationPolicy() != .regular {
            Log.app.error("activation policy is not .regular; the Dock icon and main window may be missing")
        }
        let hud = HUDPanel(controller: composition.controller)
        self.hud = hud
        observeHUDVisibility()
        // A cold machine pays the speech asset download now rather than on the first hold.
        Task {
            await AppleSpeechEngine.prepare()
        }
        if Settings.shared.speechEngine == .parakeet {
            ParakeetModels.shared.prepare()
        }
        // Before any dictation can land, so every insert is recorded for erase (§6.16).
        TextInjector.configureAccessibilityTimeout()
        TextInjector.observer = DictationEraser.shared
        if composition.controller.activate() {
            Log.app.info("hotkey active")
            startEraseMonitor()
        } else {
            Log.app.error("hotkey activation failed; prompting for Accessibility and polling")
            Permissions.promptForAccessibility()
            startAccessibilityPoll()
        }
        Log.app.info("Sotto ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityPollTask?.cancel()
        composition.controller.deactivate()
        // A paste less than half a second ago still owns the pasteboard; give it back now.
        TextInjector.flushPendingRestore()
        Log.app.info("Sotto terminating")
    }

    /// The erase input monitor, started only once the hotkey is active: a global monitor
    /// installs without Accessibility but then never sees key presses, and an epoch that
    /// never moves would vouch for a target the user had typed into (§6.16).
    private func startEraseMonitor() {
        DictationEraser.shared.start()
    }

    /// There is no notification for an Accessibility grant, so poll once a second until the
    /// process is trusted, then activate.
    private func startAccessibilityPoll() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = Task { @MainActor [weak self] in
            var polls = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.accessibilityPollInterval)
                } catch {
                    Log.app.debug("accessibility poll cancelled")
                    return
                }
                polls += 1
                guard let self else {
                    return
                }
                guard Permissions.hasAccessibility else {
                    continue
                }
                if self.composition.controller.activate() {
                    Log.app.info("Accessibility granted after \(polls, privacy: .public) polls; hotkey active")
                    self.startEraseMonitor()
                    return
                }
                Log.app.error("Accessibility trusted but hotkey activation failed; retrying")
            }
        }
    }

    /// The dictionary file may have been hand-edited while another app was frontmost, and a
    /// permission grant made in System Settings only shows up on a later check.
    func applicationDidBecomeActive(_ notification: Notification) {
        DictionaryStore.shared.reloadFromDisk()
        PermissionStatus.shared.refresh()
    }

    /// Batch B2. Presents or dismisses the HUD as `controller.state.showsHUD` changes.
    /// `withObservationTracking`'s `onChange` fires once and then stops observing, so it
    /// must re-register itself on every call to keep tracking future changes (§6.15).
    private func observeHUDVisibility() {
        withObservationTracking {
            _ = composition.controller.state
        } onChange: { [weak self] in
            // `onChange` is not guaranteed MainActor-isolated by its signature, even though
            // `state` only ever changes on the main actor; hop explicitly before touching
            // any main-actor state.
            Task { @MainActor in
                guard let self else {
                    return
                }
                if self.composition.controller.state.showsHUD {
                    self.hud?.present()
                } else {
                    self.hud?.dismiss()
                }
                self.observeHUDVisibility()
            }
        }
    }
}
