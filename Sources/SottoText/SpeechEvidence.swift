/// Whether a short hold contained any speech at all, judged by a speech detector's
/// per-window probabilities rather than by loudness (§6.7). Parakeet turns silence into
/// real words ("Yeah.", "Okay."), which `FillerOnly` must keep because people do say them;
/// only the audio can tell the two apart.
public enum SpeechEvidence {
    /// Measured 2026-09-27 on a laptop microphone in a normal room: silent holds peaked at
    /// 0.10-0.56, soft one-word answers at 0.96-1.00. The threshold sits in that gap.
    public static let threshold: Float = 0.7

    /// True when no window reaches `threshold`. No windows at all proves nothing, so it is
    /// not silence.
    public static func isSilent(_ windowProbabilities: [Float]) -> Bool {
        guard let peak = windowProbabilities.max() else {
            return false
        }
        return peak < threshold
    }
}
