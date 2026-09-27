import Foundation
import Observation

/// A cached, observable view of the two grants, so a SwiftUI body does not call
/// `AXIsProcessTrusted` (an IPC round trip to tccd) on every evaluation. Refreshed when the
/// app becomes active and by the Settings poll. Probes are injectable for tests.
@MainActor
@Observable
final class PermissionStatus {
    static let shared = PermissionStatus()

    private(set) var hasAccessibility: Bool
    private(set) var hasMicrophone: Bool

    @ObservationIgnored private let accessibility: () -> Bool
    @ObservationIgnored private let microphone: () -> Bool

    init(
        accessibility: @escaping () -> Bool = { Permissions.hasAccessibility },
        microphone: @escaping () -> Bool = { Permissions.hasMicrophone }
    ) {
        self.accessibility = accessibility
        self.microphone = microphone
        hasAccessibility = accessibility()
        hasMicrophone = microphone()
    }

    func refresh() {
        let newAccessibility = accessibility()
        let newMicrophone = microphone()
        if newAccessibility != hasAccessibility { hasAccessibility = newAccessibility }
        if newMicrophone != hasMicrophone { hasMicrophone = newMicrophone }
    }
}
