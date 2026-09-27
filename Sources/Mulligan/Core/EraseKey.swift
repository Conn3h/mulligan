import CoreGraphics

/// The key that, tapped while push to talk is held, erases the last dictation (§6.16).
/// Always a right-hand modifier: modifiers arrive as `.flagsChanged` on the tap Mulligan
/// already has, so erase needs no key-down tap and can never leak key repeats into apps.
enum EraseKey: String, CaseIterable, Sendable {
    case rightCommand
    case rightOption
    case off

    var keyCode: Int64? {
        switch self {
        case .rightCommand: PushToTalkKey.rightCommand.keyCode
        case .rightOption: PushToTalkKey.rightOption.keyCode
        case .off: nil
        }
    }

    var flag: CGEventFlags? {
        switch self {
        case .rightCommand: PushToTalkKey.rightCommand.flag
        case .rightOption: PushToTalkKey.rightOption.flag
        case .off: nil
        }
    }

    var displayName: String {
        switch self {
        case .rightCommand: PushToTalkKey.rightCommand.displayName
        case .rightOption: PushToTalkKey.rightOption.displayName
        case .off: "Off"
        }
    }

    /// True when this is the same physical key as push to talk.
    func conflicts(with key: PushToTalkKey) -> Bool {
        keyCode == key.keyCode
    }

    /// The erase key to fall back to when push to talk moves onto the current one.
    static func alternative(to key: PushToTalkKey) -> EraseKey {
        key == .rightCommand ? .rightOption : .rightCommand
    }
}
