import Foundation
import Observation

/// The UI's view of `HistoryLog`: newest run first. `HistoryLog` reloads it after every
/// write, so a panel only ever reads `runs`.
@MainActor
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    /// Newest first.
    private(set) var runs: [DictationRun] = []

    init() {
        reload()
    }

    /// `HistoryLog.record` calls this after a successful append: the new run is the newest,
    /// so it goes to the front, with no disk read.
    func prepend(_ run: DictationRun) {
        runs = [run] + runs
        Log.history.debug("history store prepended: \(self.runs.count, privacy: .public) runs")
    }

    /// `HistoryLog` calls this right after a rewrite, when it knows the file's contents
    /// without reading them back.
    func replace(withFileOrder runsInFileOrder: [DictationRun]) {
        runs = runsInFileOrder.reversed()
        Log.history.debug("history store replaced: \(self.runs.count, privacy: .public) runs")
    }

    /// A read failure leaves `runs` as they were: the file's contents are then unknown,
    /// not empty, and `HistoryLog` has already logged why.
    func reload() {
        switch HistoryLog.loadReport() {
        case .success(let report):
            runs = report.runs.reversed()
            Log.history.debug("history store reloaded: \(self.runs.count, privacy: .public) runs")
        case .failure:
            Log.history.error("history store kept its \(self.runs.count, privacy: .public) runs: the log could not be read")
        }
    }
}
