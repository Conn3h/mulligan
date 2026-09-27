import AppKit
import SwiftUI

/// The standard `Settings` scene (⌘,), spec §6.14: push-to-talk key, erase key, engine,
/// text, sound, and permission status, as one native grouped form sized to fit without
/// scrolling. `SwiftUI.Settings` is spelled out where this view is installed, in
/// `MulliganApp`, because the app has its own `Settings` type.
@MainActor
struct SettingsWindow: View {
    let controller: DictationController

    @Bindable private var settings = Settings.shared
    @State private var status = PermissionStatus.shared
    @State private var parakeet = ParakeetModels.shared

    var body: some View {
        Form {
            Section {
                Picker("Push to talk", selection: Binding(
                    get: { settings.pushToTalkKey },
                    set: { newValue in
                        settings.pushToTalkKey = newValue
                        controller.reloadHotkey()
                    }
                )) {
                    ForEach(PushToTalkKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                // §6.16. The push-to-talk key is left out of the choices; Settings would
                // move it anyway.
                Picker("Redo", selection: Binding(
                    get: { settings.eraseKey },
                    set: { newValue in
                        settings.eraseKey = newValue
                        controller.reloadHotkey()
                    }
                )) {
                    ForEach(EraseKey.allCases.filter { !$0.conflicts(with: settings.pushToTalkKey) }, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
            } header: {
                Text("Keys")
            } footer: {
                caption(eraseCaption)
            }

            Section {
                Picker("Engine", selection: Binding(
                    get: { settings.speechEngine },
                    set: { newValue in
                        settings.speechEngine = newValue
                        if newValue == .parakeet {
                            parakeet.prepare()
                        }
                    }
                )) {
                    ForEach(SpeechEngineChoice.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Speech")
            } footer: {
                caption(engineCaption)
            }

            Section {
                Toggle("Clean up dictated text", isOn: $settings.cleanupEnabled)
                Toggle("Smart cleanup", isOn: $settings.smartCleanup)
                    .disabled(!settings.cleanupEnabled || !FoundationModelFormatter.isAvailable)
                Toggle("Play a sound when listening starts", isOn: $settings.soundEnabled)
            } header: {
                Text("Text and sound")
            } footer: {
                if settings.cleanupEnabled, !FoundationModelFormatter.isAvailable,
                   let reason = FoundationModelFormatter.unavailableReason {
                    caption(reason)
                }
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Accessibility",
                    granted: status.hasAccessibility,
                    open: Permissions.openAccessibilitySettings
                )
                PermissionRow(
                    title: "Microphone",
                    granted: status.hasMicrophone,
                    open: Permissions.openMicrophoneSettings
                )
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: DS.Metric.settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            refreshPermissions()
        }
        .task {
            await pollPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.inkTertiary)
    }

    private var eraseCaption: String {
        guard settings.eraseKey != .off else {
            return "Erasing is off."
        }
        return "Hold \(settings.pushToTalkKey.displayName) and press \(settings.eraseKey.displayName) to remove your last dictation and say it again."
    }

    private var engineCaption: String {
        switch settings.speechEngine {
        case .apple:
            return "Apple's on-device recognizer. Dictionary words bias recognition."
        case .parakeet:
            return parakeetCaption
        }
    }

    private var parakeetCaption: String {
        switch parakeet.state {
        case .idle:
            return "NVIDIA Parakeet, on device. Models download on first use."
        case .downloading(let fraction):
            let percent = Int((fraction * 100).rounded(.down))
            return "Downloading Parakeet models, \(percent)%."
        case .loading:
            return "Loading Parakeet models."
        case .ready:
            return "NVIDIA Parakeet, on device. Dictionary words bias recognition."
        case .failed(let reason):
            return "Parakeet failed to load: \(reason)"
        }
    }

    private func refreshPermissions() {
        PermissionStatus.shared.refresh()
    }

    private func pollPermissions() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(DS.Motion.permissionPollInterval))
            } catch {
                Log.app.debug("permission poll cancelled")
                return
            }
            refreshPermissions()
        }
    }
}
