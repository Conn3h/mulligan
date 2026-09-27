import Foundation
import MulliganText
import Synchronization

/// Smart cleanup: the on-device model raced against a timeout, its output checked by
/// `CleanupGuard`, with `RuleBasedFormatter` as the fallback on every other path. A stalled
/// model must never cost the user an utterance they already spoke.
struct FoundationModelFormatter: TextFormatter {
    private enum Outcome: Sendable {
        case cleaned(String)
        case failed(String)
        case timedOut
    }

    /// A one-shot slot: the first outcome wins and wakes the single waiter; anything later
    /// is dropped. This is what lets `format` walk away from a stalled model without
    /// awaiting it, which a structured task group cannot do.
    private final class RaceSlot: Sendable {
        private struct State: Sendable {
            var outcome: Outcome?
            var waiter: CheckedContinuation<Outcome, Never>?
        }

        private let state = Mutex(State())

        /// Stores the outcome and wakes the waiter. Returns false when an earlier outcome
        /// already won, in which case this one is discarded.
        @discardableResult
        func fulfill(_ outcome: Outcome) -> Bool {
            let (won, waiter): (Bool, CheckedContinuation<Outcome, Never>?) = state.withLock { state in
                guard state.outcome == nil else {
                    return (false, nil)
                }
                state.outcome = outcome
                let waiter = state.waiter
                state.waiter = nil
                return (true, waiter)
            }
            waiter?.resume(returning: outcome)
            return won
        }

        func value() async -> Outcome {
            await withCheckedContinuation { continuation in
                let ready: Outcome? = state.withLock { state in
                    if let outcome = state.outcome {
                        return outcome
                    }
                    state.waiter = continuation
                    return nil
                }
                if let ready {
                    continuation.resume(returning: ready)
                }
            }
        }
    }

    private let model: any CleanupModel
    private let timeout: Duration
    private let rules = RuleBasedFormatter()

    init(model: any CleanupModel = SystemCleanupModel(), timeout: Duration = .seconds(4)) {
        self.model = model
        self.timeout = timeout
    }

    static var isAvailable: Bool {
        SystemCleanupModel().isAvailable
    }

    static var unavailableReason: String? {
        SystemCleanupModel().unavailableReason
    }

    func format(_ raw: String) async -> String {
        let transcript = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return ""
        }
        guard model.isAvailable else {
            let reason = model.unavailableReason ?? "no reason given"
            Log.app.info("smart cleanup unavailable (\(reason, privacy: .public)); using rules")
            return await rules.format(transcript)
        }

        switch await race(transcript) {
        case .cleaned(let output):
            let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
            switch CleanupGuard.evaluate(original: transcript, cleaned: cleaned) {
            case .accepted:
                Log.app.info(
                    "smart cleanup accepted: \(transcript.count, privacy: .public) -> \(cleaned.count, privacy: .public) chars"
                )
                return cleaned
            case .rejected(let reason):
                Log.app.info("smart cleanup rejected (\(Self.kind(of: reason), privacy: .public)); using rules")
                return await rules.format(transcript)
            }
        case .failed(let description):
            Log.app.error("smart cleanup failed: \(description, privacy: .public); using rules")
            return await rules.format(transcript)
        case .timedOut:
            Log.app.error("smart cleanup timed out after \(String(describing: self.timeout), privacy: .public); using rules")
            return await rules.format(transcript)
        }
    }

    /// Runs the model in an unstructured task and races it against `Task.sleep`. Whichever
    /// finishes first wins; the loser is cancelled and abandoned, never awaited.
    private func race(_ transcript: String) async -> Outcome {
        let slot = RaceSlot()
        let model = self.model
        let timeout = self.timeout

        let modelTask = Task {
            do {
                let cleaned = try await model.cleanup(transcript)
                if !slot.fulfill(.cleaned(cleaned)) {
                    Log.app.info("smart cleanup result arrived after the timeout; discarded")
                }
            } catch {
                if !slot.fulfill(.failed(error.localizedDescription)) {
                    Log.app.debug("smart cleanup failure arrived after the timeout; discarded")
                }
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                slot.fulfill(.timedOut)
            } catch {
                Log.app.debug("smart cleanup timer cancelled: the model answered first")
            }
        }

        let outcome = await slot.value()
        if case .timedOut = outcome {
            modelTask.cancel()
        } else {
            timer.cancel()
        }
        return outcome
    }

    /// The reason without its word list: `invented: w1, w2` can carry the model's output,
    /// and only the category is needed to diagnose a rejection.
    private static func kind(of reason: String) -> String {
        String(reason.split(separator: ":", maxSplits: 1).first ?? Substring(reason))
    }
}
