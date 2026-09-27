import Foundation
import Testing
@testable import Mulligan

/// Day sections for the History tab: newest day first, runs keep their newest-first order,
/// and each day carries its dictation and word counts.
@Suite
struct HistoryDaysTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private let locale = Locale(identifier: "en_GB")

    /// Sunday 28 September 2026, 10:42 London time.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 10, minute: 42))!
    }

    private func at(day: Int, month: Int = 9, year: Int = 2026, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func run(_ text: String, _ date: Date) -> DictationRun {
        DictationRun(date: date, engine: "Parakeet", source: "hotkey", audioSeconds: 1, processSeconds: 0.1, text: text)
    }

    @Test func groupsNewestFirstRunsByCalendarDay() {
        let runs = [
            run("third today", at(day: 28, hour: 10)),
            run("first today", at(day: 28, hour: 9)),
            run("yesterday evening", at(day: 27, hour: 18)),
            run("older", at(day: 25, hour: 8)),
        ]
        let days = HistoryDays.group(runs, now: now, calendar: calendar, locale: locale)
        #expect(days.map(\.title) == ["Today", "Yesterday", "Friday 25 September"])
        #expect(days[0].runs.map(\.text) == ["third today", "first today"])
        #expect(days[1].runs.count == 1)
    }

    @Test func aDayFromAnotherYearCarriesTheYear() {
        let days = HistoryDays.group([run("old", at(day: 3, month: 1, year: 2025, hour: 12))], now: now, calendar: calendar, locale: locale)
        #expect(days.map(\.title) == ["3 January 2025"])
    }

    @Test func countsWordsAcrossTheDay() {
        let runs = [
            run("Looks good to me.", at(day: 28, hour: 10)),
            run("  merge   it\nnow ", at(day: 28, hour: 9)),
        ]
        let days = HistoryDays.group(runs, now: now, calendar: calendar, locale: locale)
        #expect(days[0].wordCount == 7)
    }

    @Test func noRunsNoDays() {
        #expect(HistoryDays.group([], now: now, calendar: calendar, locale: locale).isEmpty)
    }

    @Test func summaryReadsSingularAndPlural() {
        #expect(HistoryDays.summary(dictations: 1, words: 1) == "1 dictation · 1 word")
        #expect(HistoryDays.summary(dictations: 1232, words: 21480) == "1,232 dictations · 21,480 words")
    }
}
