import CoreGraphics
import Testing
@testable import Mulligan

struct EraseKeyTests {
    @Test func modifiersUseTheSameCodesAndBitsAsPushToTalk() {
        #expect(EraseKey.rightCommand.keyCode == PushToTalkKey.rightCommand.keyCode)
        #expect(EraseKey.rightCommand.flag == PushToTalkKey.rightCommand.flag)
        #expect(EraseKey.rightOption.keyCode == PushToTalkKey.rightOption.keyCode)
        #expect(EraseKey.rightOption.flag == PushToTalkKey.rightOption.flag)
        #expect(EraseKey.off.keyCode == nil)
        #expect(EraseKey.off.flag == nil)
    }

    @Test func conflictsOnlyWithTheSamePhysicalKey() {
        #expect(EraseKey.rightCommand.conflicts(with: .rightCommand))
        #expect(!EraseKey.rightCommand.conflicts(with: .rightOption))
        #expect(EraseKey.rightOption.conflicts(with: .rightOption))
        #expect(!EraseKey.rightOption.conflicts(with: .fn))
        #expect(!EraseKey.off.conflicts(with: .rightOption))
    }

    @Test func alternativeIsTheOtherRightModifier() {
        #expect(EraseKey.alternative(to: .rightOption) == .rightCommand)
        #expect(EraseKey.alternative(to: .rightCommand) == .rightOption)
        #expect(EraseKey.alternative(to: .fn) == .rightCommand)
    }
}
