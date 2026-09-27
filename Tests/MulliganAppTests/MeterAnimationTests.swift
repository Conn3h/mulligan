import Testing
@testable import Mulligan

@Suite
struct MeterAnimationTests {
    @Test func stillWhenWindowHidden() {
        #expect(!MeterAnimation.shouldAnimate(isActive: true, reduceMotion: false, windowVisible: false))
        #expect(!MeterAnimation.shouldAnimate(isActive: false, reduceMotion: false, windowVisible: false))
    }

    @Test func idleRippleOnlyWhenVisibleAndMotionAllowed() {
        #expect(MeterAnimation.shouldAnimate(isActive: false, reduceMotion: false, windowVisible: true))
        #expect(!MeterAnimation.shouldAnimate(isActive: false, reduceMotion: true, windowVisible: true))
    }

    @Test func recordingAnimatesEvenWithReduceMotionWhenVisible() {
        // The recording meter still needs to track level with reduce motion on; it just
        // does not add decorative motion. Visibility still gates it.
        #expect(MeterAnimation.shouldAnimate(isActive: true, reduceMotion: true, windowVisible: true))
        #expect(!MeterAnimation.shouldAnimate(isActive: true, reduceMotion: true, windowVisible: false))
    }
}
