import Testing
@testable import Mulligan

@MainActor
@Suite
struct PermissionStatusTests {
    @Test func refreshReflectsTheProbes() {
        var accessibility = false
        var microphone = false
        let status = PermissionStatus(
            accessibility: { accessibility },
            microphone: { microphone }
        )
        #expect(!status.hasAccessibility)
        #expect(!status.hasMicrophone)

        accessibility = true
        microphone = true
        status.refresh()
        #expect(status.hasAccessibility)
        #expect(status.hasMicrophone)
    }
}
