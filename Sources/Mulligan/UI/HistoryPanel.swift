import AppKit
import Observation
import MulliganDictionary
import SwiftUI

/// The History tab (spec §6.14): search and "Copy last", then runs grouped by day under
/// sticky day headers (newest first; `HistoryStore.shared.runs` is already ordered that way),
/// rows with an always-visible copy button and a hover-only delete with no confirmation, and
/// a footer whose "Delete all…" does confirm.
@MainActor
struct HistoryPanel: View {
    @State private var query = ""
    @State private var confirmingDeleteAll = false
    @State private var copiedLast = CopyFeedback()

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
            HStack(spacing: DS.Space.base) {
                SearchField(text: $query, placeholder: "Search history")
                copyLastButton
            }
            .padding(.horizontal, DS.Space.roomy)
            .padding(.vertical, DS.Space.base)
            .overlay(
                Rectangle().fill(DS.Color.hairline).frame(height: DS.Border.hairline),
                alignment: .bottom
            )

            if filtered.isEmpty {
                EmptyStateView(
                    systemImage: "clock",
                    title: query.isEmpty ? "No dictations yet" : "No matches",
                    message: query.isEmpty
                        ? "Hold \(Settings.shared.pushToTalkKey.displayName) anywhere and talk. What you say lands here too."
                        : "Try a different search."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.none, pinnedViews: [.sectionHeaders]) {
                        ForEach(HistoryDays.group(filtered)) { day in
                            Section {
                                ForEach(day.runs) { run in
                                    HistoryRow(run: run)
                                }
                            } header: {
                                DayHeader(day: day)
                            }
                        }
                    }
                    .padding(.bottom, DS.Space.roomy)
                }
            }

            footer
        }
    }

    private var copyLastButton: some View {
        Button {
            guard let last = runs.first else {
                return
            }
            copiedLast.copy(last.text)
        } label: {
            HStack(spacing: DS.Space.tight) {
                Image(systemName: copiedLast.isShowing ? "checkmark" : "doc.on.doc")
                Text(copiedLast.isShowing ? "Copied" : "Copy last")
            }
        }
        .keyboardShortcut("c", modifiers: [.command, .option])
        .disabled(runs.isEmpty)
        .help("Copy the last dictation (\u{2325}\u{2318}C)")
        .onDisappear {
            copiedLast.cancel()
        }
    }

    private var footer: some View {
        HStack {
            Text(HistoryDays.summary(
                dictations: runs.count,
                words: runs.reduce(0) { $0 + HistoryDays.wordCount($1.text) }
            ))
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.inkTertiary)
            Spacer()
            Button("Delete all\u{2026}") {
                confirmingDeleteAll = true
            }
            .buttonStyle(.plain)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.inkSecondary)
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
        .padding(.vertical, DS.Space.snug)
        .overlay(
            Rectangle().fill(DS.Color.hairline).frame(height: DS.Border.hairline),
            alignment: .top
        )
    }
}

/// A sticky day header: the day ("Today", "Yesterday", "Friday 25 September") and its
/// dictation and word counts.
@MainActor
private struct DayHeader: View {
    let day: HistoryDay

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(day.title.uppercased())
                .font(DS.Font.eyebrow)
                .tracking(DS.Metric.eyebrowTracking)
                .foregroundStyle(DS.Color.inkSecondary)
            Spacer()
            Text(HistoryDays.summary(dictations: day.runs.count, words: day.wordCount))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkTertiary)
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.top, DS.Space.base)
        .padding(.bottom, DS.Space.tight)
        .background(DS.Color.panel)
    }
}

/// Copies text and shows "Copied" for `DS.Metric.copiedFeedbackSeconds`. Each copy bumps a
/// generation so only the newest timer may clear the feedback: an earlier click can never
/// clear the state a later click just set.
@MainActor
@Observable
private final class CopyFeedback {
    private(set) var isShowing = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(text, forType: .string) {
            Log.history.error("copy failed: pasteboard did not accept the string")
        }
        isShowing = true
        task?.cancel()
        generation += 1
        let current = generation
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(DS.Metric.copiedFeedbackSeconds))
            } catch {
                Log.app.debug("copy feedback timer cancelled")
                return
            }
            guard let self, current == self.generation else {
                return
            }
            self.isShowing = false
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// One run: a fixed-width time-of-day column, the transcript with its correction badges, and
/// at the trailing edge an always-visible copy button plus a hover-only delete. The engine,
/// source and timing sit in the row's tooltip rather than on a line of their own.
@MainActor
private struct HistoryRow: View {
    let run: DictationRun

    @State private var isHovering = false
    @State private var copied = CopyFeedback()

    private static let timeOfDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let locale = Locale(identifier: "en_US_POSIX")

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.base) {
            Text(Self.timeOfDay.string(from: run.date))
                .font(DS.Font.caption.monospacedDigit())
                .foregroundStyle(DS.Color.inkTertiary)
                .frame(width: DS.Metric.historyTimeColumnWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: DS.Space.snug) {
                Text(run.text)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let corrections = run.corrections, !corrections.isEmpty {
                    HStack(spacing: DS.Space.snug) {
                        ForEach(corrections.indices, id: \.self) { index in
                            CorrectionBadge(correction: corrections[index])
                        }
                    }
                }
            }

            HStack(spacing: DS.Space.tight) {
                Button {
                    HistoryLog.delete(ids: [run.id])
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityLabel("Delete recording")
                .opacity(isHovering ? 1 : 0)
                .disabled(!isHovering)

                Button {
                    copied.copy(run.text)
                } label: {
                    Image(systemName: copied.isShowing ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(RowButtonStyle(emphasised: isHovering))
                .accessibilityLabel(copied.isShowing ? "Copied" : "Copy")
                .help("Copy")
            }
            // Centre the buttons on the first line of text rather than hanging them from
            // its baseline: a body line's visual centre sits about `tight` above it.
            .alignmentGuide(.firstTextBaseline) { dimensions in
                dimensions[VerticalAlignment.center] + DS.Space.tight
            }
        }
        .padding(.horizontal, DS.Space.snug)
        .padding(.vertical, DS.Space.snug)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(isHovering ? DS.Color.panelRaised : DS.Color.clear)
        )
        .padding(.horizontal, DS.Space.snug)
        .help(metaLine)
        .onHover { hovering in
            isHovering = hovering
        }
        .onDisappear {
            copied.cancel()
        }
    }

    private var sourceLabel: String {
        run.source == "hotkey" ? "typed" : "recorded"
    }

    private var metaLine: String {
        let seconds = String(format: "%.2f s", locale: Self.locale, run.processSeconds)
        return "\(run.engine) \u{00B7} \(sourceLabel) \u{00B7} \(seconds)"
    }
}

/// A History row's small square icon button: quiet at rest, a raised fill on press.
@MainActor
private struct RowButtonStyle: ButtonStyle {
    var emphasised = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.caption)
            .foregroundStyle(emphasised ? DS.Color.ink : DS.Color.inkTertiary)
            .frame(width: DS.Metric.rowButtonSize, height: DS.Metric.rowButtonSize)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(configuration.isPressed ? DS.Color.selection : DS.Color.clear)
            )
            .contentShape(Rectangle())
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
