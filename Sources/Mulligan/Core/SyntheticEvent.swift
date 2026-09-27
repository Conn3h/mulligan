import CoreGraphics

/// Marks the events Mulligan posts itself (the paste's Command-V, an erase's backspaces), so its
/// input monitor does not mistake them for the user typing (§6.16).
enum SyntheticEvent {
    /// "SOTTO" in ASCII.
    static let marker: Int64 = 0x53_4F_54_54_4F

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    static func isMarked(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
