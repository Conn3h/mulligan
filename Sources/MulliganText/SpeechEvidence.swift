/// Whether a short hold contained any speech at all, judged by a speech detector's
/// per-window probabilities rather than by loudness (§6.7). Parakeet turns silence into
/// real words ("Yeah.", "Okay."), which `FillerOnly` must keep because people do say them;
/// only the audio can tell the two apart.
public enum SpeechEvidence {
    /// Measured 2026-09-27 on a laptop microphone in a normal room, first window left out:
    /// silent holds peaked at 0.02-0.46, one-word answers at 0.86-1.00. The threshold sits
    /// in that gap.
    public static let threshold: Float = 0.7

    /// True when no window reaches `threshold`. With `ignoringFirstWindow` (the start sound
    /// played), the first window is left out whenever later ones exist: it holds that sound,
    /// which once scored 0.94 on a silent hold, while every measured answer peaked in a later
    /// window. Without the sound it counts, so a quick word that lives only there is kept. No
    /// windows at all proves nothing, so it is not silence.
    public static func isSilent(_ windowProbabilities: [Float], ignoringFirstWindow: Bool = true) -> Bool {
        let skipFirst = ignoringFirstWindow && windowProbabilities.count > 1
        let judged = skipFirst ? windowProbabilities.dropFirst() : windowProbabilities[...]
        guard let peak = judged.max() else {
            return false
        }
        return peak < threshold
    }
}
