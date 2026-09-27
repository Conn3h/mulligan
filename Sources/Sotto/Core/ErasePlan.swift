import ApplicationServices
import Foundation

/// An accessibility element compared by `CFEqual`, the only identity AX offers. It is
/// compared, never messaged, away from the main actor.
struct AXElementID: @unchecked Sendable, Equatable {
    let element: AXUIElement

    static func == (lhs: AXElementID, rhs: AXElementID) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

/// What `TextInjector` knew about the previous injection. Restored after an erase so the
/// restated text does not inherit the run-on leading space meant for the erased one.
struct LastInjectionSnapshot: Sendable, Equatable {
    let bundleID: String?
    let at: ContinuousClock.Instant
    let endedInWhitespace: Bool
}

/// What was last typed, captured when the insert was confirmed (§6.16).
struct TypedDictation: Sendable, Equatable {
    /// Exactly as delivered, including any leading space Sotto added.
    let text: String
    /// The frontmost app before the insert began.
    let processID: pid_t
    /// The focused element, when readable.
    let element: AXElementID?
    /// The focused element's window, when readable.
    let window: AXElementID?
    /// UTF-16 caret location after the insert, when readable.
    let caretEnd: Int?
    let landedAt: ContinuousClock.Instant
    let previousInjection: LastInjectionSnapshot?
    /// The input monitor's epoch before the insert began.
    let inputEpoch: UInt64
    /// The delivery this insert belongs to. Only the current delivery's landing makes the
    /// record current again; an older paste settling late must not (§6.16).
    var generation: UInt64 = 0

    /// Whether the focus and caret read after an insert can be trusted as that insert's: only
    /// when the input monitor is running and saw nothing while the text landed. Otherwise a
    /// click beside an older identical phrase could become the record's caret (§6.16).
    static func landingIsTrusted(monitoring: Bool, epochBefore: UInt64, epochNow: UInt64) -> Bool {
        monitoring && epochBefore == epochNow
    }
}

/// The target as it reads right now.
enum ReadBack: Equatable {
    /// No readable text. The window is still named when AX can find one (terminals often can).
    case unreadable(window: AXElementID?)
    /// `preceding` is the record's UTF-16 length of text ending at the selection's end, nil
    /// when that range is out of bounds.
    case readable(element: AXElementID, window: AXElementID?, selection: CFRange, preceding: String?)

    static func == (lhs: ReadBack, rhs: ReadBack) -> Bool {
        switch (lhs, rhs) {
        case let (.unreadable(left), .unreadable(right)):
            return left == right
        case let (.readable(leftElement, leftWindow, leftSelection, leftText),
                  .readable(rightElement, rightWindow, rightSelection, rightText)):
            return leftElement == rightElement && leftWindow == rightWindow
                && leftSelection.location == rightSelection.location
                && leftSelection.length == rightSelection.length
                && leftText == rightText
        default:
            return false
        }
    }
}

enum EraseOutcome: Sendable, Equatable {
    case erased
    case nothingToErase
    case notTyped
    case inputSince
    case textChanged
    case tooLongToVerify
    case interrupted
    case failed

    /// What the HUD shows; nil when the erase happened.
    var message: String? {
        switch self {
        case .erased: nil
        case .nothingToErase: "Nothing to erase."
        case .notTyped: "The last dictation wasn't typed; nothing was erased."
        case .inputSince: "You've typed, clicked or switched since; nothing was erased."
        case .textChanged: "The text before the cursor changed; nothing was erased."
        case .tooLongToVerify: "That dictation is too long or has line breaks, so it can't be erased safely here."
        case .interrupted: "Erasing stopped part-way because you typed or switched; check the text."
        case .failed: "Couldn't erase; nothing was changed."
        }
    }
}

/// Whether and how to erase (§6.16 "Plan"). Pure, so every safety rule is unit-tested. Text
/// read back from the target is proof; the input epoch is only inference, used when the
/// target cannot be read.
enum ErasePlan: Equatable {
    case refuse(EraseOutcome)
    /// Readable and proven: delete this UTF-16 range.
    case deleteRange(location: Int, length: Int)
    /// Unreadable and inferred untouched: post this many backspaces (Characters).
    case backspaces(count: Int)

    /// Claude Code folds a paste of more than 800 characters, and Codex CLI one of more than
    /// 1000, into a placeholder a single backspace deletes whole (§10).
    static let unverifiedLimit = 500

    static func decide(
        record: TypedDictation?,
        superseded: Bool,
        epoch: UInt64,
        frontmostPID: pid_t?,
        readBack: ReadBack
    ) -> ErasePlan {
        guard let record else {
            return .refuse(.nothingToErase)
        }
        guard !superseded else {
            return .refuse(.notTyped)
        }
        guard frontmostPID == record.processID else {
            return .refuse(.inputSince)
        }
        // A field that was readable when Sotto typed into it is erased on proof or not at all:
        // unreadable now means focus moved, and without the caret there is nothing to prove.
        if let recordedElement = record.element {
            guard case let .readable(element, window, selection, preceding) = readBack else {
                return .refuse(.inputSince)
            }
            guard let caretEnd = record.caretEnd else {
                return .refuse(.textChanged)
            }
            return decideReadable(
                record: record, recordedElement: recordedElement, caretEnd: caretEnd,
                element: element, window: window, selection: selection, preceding: preceding
            )
        }
        return decideUnverified(record: record, epoch: epoch, readBack: readBack)
    }

    /// The field Sotto typed into, read back: same element, the caret (or the insertion
    /// selected) exactly where the insert left it, and the same text before it.
    private static func decideReadable(
        record: TypedDictation,
        recordedElement: AXElementID,
        caretEnd: Int,
        element: AXElementID,
        window: AXElementID?,
        selection: CFRange,
        preceding: String?
    ) -> ErasePlan {
        guard element == recordedElement else {
            return .refuse(.inputSince)
        }
        if let window, let recordedWindow = record.window, window != recordedWindow {
            return .refuse(.inputSince)
        }
        let length = record.text.utf16.count
        let start = caretEnd - length
        let isCaret = selection.length == 0 && selection.location == caretEnd
        let isInsertion = selection.location == start && selection.length == length
        guard start >= 0, isCaret || isInsertion, sameUnits(preceding, record.text) else {
            return .refuse(.textChanged)
        }
        return .deleteRange(location: start, length: length)
    }

    /// No proof from the target: nothing may have happened since the insert, and the text
    /// must be short and single-line enough that terminals kept it as typed characters.
    private static func decideUnverified(record: TypedDictation, epoch: UInt64, readBack: ReadBack) -> ErasePlan {
        guard epoch == record.inputEpoch else {
            return .refuse(.inputSince)
        }
        let window: AXElementID?
        switch readBack {
        case .unreadable(let current):
            window = current
        case .readable(_, let current, let selection, let preceding):
            window = current
            // A selection (the paste left selected, say) would swallow the first backspace
            // whole, and the rest would eat older text.
            guard selection.length == 0, sameUnits(preceding, record.text) else {
                return .refuse(.textChanged)
            }
        }
        if let window, let recordedWindow = record.window, window != recordedWindow {
            return .refuse(.inputSince)
        }
        guard !record.text.contains(where: \.isNewline), record.text.count <= unverifiedLimit else {
            return .refuse(.tooLongToVerify)
        }
        return .backspaces(count: record.text.count)
    }

    /// UTF-16 unit for unit. Swift's `==` treats canonically equivalent strings as equal, but
    /// an app that normalised the text has changed it, and its length in the field with it.
    private static func sameUnits(_ read: String?, _ typed: String) -> Bool {
        guard let read else {
            return false
        }
        return read.utf16.elementsEqual(typed.utf16)
    }
}
