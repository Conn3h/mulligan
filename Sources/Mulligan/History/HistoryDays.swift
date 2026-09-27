import Foundation

/// One calendar day of History: its title ("Today", "Yesterday", "Friday 25 September"), its
/// runs newest first, and its word count.
struct HistoryDay: Identifiable {
    /// The start of the day, in the grouping calendar.
    let id: Date
    let title: String
    let runs: [DictationRun]
    let wordCount: Int
}

/// Splits History into day sections (spec §6.14). Pure, so the grouping and the titles are
/// tested without a view.
enum HistoryDays {
    /// Days come out newest first, each with its runs newest first. Runs are grouped by
    /// calendar day over the whole list, not by adjacency: History is in insertion order,
    /// and a clock or time-zone change can interleave days in it.
    static func group(
        _ runs: [DictationRun],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [HistoryDay] {
        let byDay = Dictionary(grouping: runs) { calendar.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { start in
            let dayRuns = (byDay[start] ?? []).sorted { $0.date > $1.date }
            return HistoryDay(
                id: start,
                title: title(for: start, now: now, calendar: calendar, locale: locale),
                runs: dayRuns,
                wordCount: dayRuns.reduce(0) { $0 + wordCount($1.text) }
            )
        }
    }

    static func title(for day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEEdMMMM" : "dMMMMyyyy")
        return formatter.string(from: day)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// "1,232 dictations · 21,480 words", for a day header or the footer.
    static func summary(dictations: Int, words: Int, locale: Locale = Locale(identifier: "en_US")) -> String {
        let dictationText = "\(dictations.formatted(.number.locale(locale))) dictation\(dictations == 1 ? "" : "s")"
        let wordText = "\(words.formatted(.number.locale(locale))) word\(words == 1 ? "" : "s")"
        return "\(dictationText) \u{00B7} \(wordText)"
    }
}
