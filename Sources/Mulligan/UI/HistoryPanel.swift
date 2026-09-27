import AppKit
import MulliganDictionary
import SwiftUI

/// The History tab (spec §6.14): search, newest-first runs (`HistoryStore.shared.runs` is
/// already ordered that way), hover-to-delete rows with no confirmation, and a footer whose
/// "Delete all…" does confirm.
@MainActor
struct HistoryPanel: View {
    @State private var query = ""
    @State private var confirmingDeleteAll = false

    private var runs: [DictationRun] {
        HistoryStore.shared.runs
    }

    private var filtered: [DictationRun] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return runs
        }
        return runs.filter { $0.text.localizedStandardContains(needle) }
    }

    var body: some View {
        VStack(spacing: DS.Space.none) {
            SearchField(text: $query, placeholder: "Search history")
                .padding(.horizontal, DS.Space.roomy)
                .padding(.vertical, DS.Space.base)

            if filtered.isEmpty {
                EmptyStateView(
                    systemImage: "clock",
                    title: query.isEmpty ? "No dictations yet" : "No matches",
                    message: query.isEmpty
                        ? "Hold \(Settings.shared.pushToTalkKey.displayName) anywhere, or press Record above."
                        : "Try a different search."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.none) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, run in
                            if index > 0 {
                                Rectangle()
                                    .fill(DS.Color.hairline)
                                    .frame(height: DS.Border.hairline)
                            }
                            HistoryRow(run: run)
                        }
                    }
                    .padding(.bottom, DS.Space.roomy)
                }
            }

            footer
        }
    }

    private var footer: some View {
        HStack {
            Text("\(runs.count) recording\(runs.count == 1 ? "" : "s")")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkTertiary)
            Spacer()
            Button("Delete all\u{2026}") {
                confirmingDeleteAll = true
            }
            .disabled(runs.isEmpty)
            .confirmationDialog(
                "Delete all recordings?",
                isPresented: $confirmingDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    HistoryLog.clear()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every recording from History. This cannot be undone.")
            }
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.base)
        .background(DS.Color.panel)
        .overlay(
            Rectangle().fill(DS.Color.hairline).frame(height: DS.Border.hairline),
            alignment: .top
        )
    }
}

/// One run: a fixed-width time-of-day column, the transcript, a meta line ("Apple · typed ·
/// 0.15 s"), correction badges when any fired, and a hover-only Copy/Delete cluster at the
/// trailing edge. Flush to the well's full width — a hairline separates rows, not a card.
@MainActor
private struct HistoryRow: View {
    let run: DictationRun

    @State private var isHovering = false
    @State private var showCopied = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    /// Bumped per click so only the newest timer may clear the feedback or the handle.
    @State private var copyGeneration = 0

    private static let timeOfDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let locale = Locale(identifier: "en_US_POSIX")

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.base) {
            Text(Self.timeOfDay.string(from: run.date))
                .font(DS.Font.caption.monospacedDigit())
                .foregroundStyle(DS.Color.inkTertiary)
                .frame(width: DS.Metric.historyTimeColumnWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: DS.Space.snug) {
                Text(run.text)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .textSelection(.enabled)

                Text(metaLine)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkTertiary)

                if let corrections = run.corrections, !corrections.isEmpty {
                    HStack(spacing: DS.Space.snug) {
                        ForEach(corrections.indices, id: \.self) { index in
                            CorrectionBadge(correction: corrections[index])
                        }
                    }
                }
            }

            Spacer(minLength: DS.Space.roomy)

            if isHovering {
                HStack(spacing: DS.Space.base) {
                    Button {
                        HistoryLog.delete(ids: [run.id])
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(DS.Color.inkSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete recording")

                    Button {
                        copy()
                    } label: {
                        Text(showCopied ? "Copied" : "Copy")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.inkSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.base)
        .background(isHovering ? DS.Color.panel : DS.Color.clear)
        .onHover { hovering in
            isHovering = hovering
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
        }
    }

    private var sourceLabel: String {
        run.source == "hotkey" ? "typed" : "recorded"
    }

    private var metaLine: String {
        let seconds = String(format: "%.2f s", locale: Self.locale, run.processSeconds)
        return "\(run.engine) \u{00B7} \(sourceLabel) \u{00B7} \(seconds)"
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        let didSet = NSPasteboard.general.setString(run.text, forType: .string)
        if !didSet {
            Log.history.error("copy failed: pasteboard did not accept the string")
        }
        showCopied = true

        // Cancel any feedback timer already running for this row, so an earlier click can
        // never clear the "Copied" state a later click just set.
        copyFeedbackTask?.cancel()
        copyGeneration += 1
        let generation = copyGeneration
        copyFeedbackTask = Task {
            do {
                try await Task.sleep(for: .seconds(DS.Metric.copiedFeedbackSeconds))
            } catch {
                // A newer click owns the handle now; leave it alone.
                Log.app.debug("copy feedback timer cancelled")
                return
            }
            guard generation == copyGeneration else {
                return
            }
            showCopied = false
            copyFeedbackTask = nil
        }
    }
}

/// "heard" → "written", struck through, with a ×count when the entry fired more than once.
@MainActor
private struct CorrectionBadge: View {
    let correction: AppliedCorrection

    var body: some View {
        Chip {
            HStack(spacing: DS.Space.hair) {
                Text(correction.from).strikethrough()
                Image(systemName: "arrow.right")
                Text(correction.to)
                if correction.count > 1 {
                    Text("\u{00D7}\(correction.count)")
                }
            }
        }
    }
}
