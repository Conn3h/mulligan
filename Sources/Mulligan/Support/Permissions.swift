import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// The two grants Mulligan cannot work without: Accessibility (event tap, AX insertion) and
/// Microphone. Neither can be requested silently; both are keyed to the code signature.
@MainActor
enum Permissions {
    /// `kAXTrustedCheckOptionPrompt` imports as a mutable global, which strict concurrency
    /// rejects, so the key is spelled out.
    private static let accessibilityPromptOption = "AXTrustedCheckOptionPrompt"
    private static let accessibilitySettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    private static let microphoneSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Shows the system Accessibility prompt when the app is not yet trusted. Returns the
    /// current trust state; a grant made in the prompt only shows up on a later check.
    @discardableResult
    static func promptForAccessibility() -> Bool {
        let options = [accessibilityPromptOption: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Log.app.info("accessibility prompt shown; trusted: \(trusted, privacy: .public)")
        return trusted
    }

    static func requestMicrophone() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Log.audio.info("microphone access requested; granted: \(granted, privacy: .public)")
            return granted
        case .denied, .restricted:
            Log.audio.error("microphone access unavailable: status \(status.rawValue, privacy: .public)")
            return false
        @unknown default:
            Log.audio.error("microphone access in unknown state: status \(status.rawValue, privacy: .public)")
            return false
        }
    }

    static func openAccessibilitySettings() {
        open(accessibilitySettingsURL, label: "Accessibility")
    }

    static func openMicrophoneSettings() {
        open(microphoneSettingsURL, label: "Microphone")
    }

    private static func open(_ string: String, label: String) {
        guard let url = URL(string: string) else {
            Log.app.error("\(label, privacy: .public) settings URL is malformed")
            return
        }
        guard NSWorkspace.shared.open(url) else {
            Log.app.error("could not open \(label, privacy: .public) settings")
            return
        }
        Log.app.info("opened \(label, privacy: .public) settings")
    }
}
