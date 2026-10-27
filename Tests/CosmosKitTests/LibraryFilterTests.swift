import Foundation
import Testing
@testable import CosmosKit
@testable import CosmosCore

/// The Filter menu beside each Library section's search field: what each choice lets through.
@Suite struct LibraryFilterTests {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    /// Wednesday 14:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    @Test func allTimeLetsEveryVisitThrough() {
        #expect(HistoryWindow.allTime.contains(.distantPast, now: now, calendar: calendar))
        #expect(HistoryWindow.allTime.contains(now, now: now, calendar: calendar))
    }

    @Test func todayIsSinceMidnightAndYesterdayIsTheDayBefore() {
        let midnight = calendar.startOfDay(for: now)
        #expect(HistoryWindow.today.contains(midnight, now: now, calendar: calendar))
        #expect(!HistoryWindow.today.contains(midnight.addingTimeInterval(-1), now: now, calendar: calendar))
        #expect(HistoryWindow.yesterday.contains(midnight.addingTimeInterval(-1), now: now, calendar: calendar))
        #expect(HistoryWindow.yesterday.contains(midnight.addingTimeInterval(-86_400), now: now, calendar: calendar))
        #expect(!HistoryWindow.yesterday.contains(midnight, now: now, calendar: calendar))
        #expect(!HistoryWindow.yesterday.contains(midnight.addingTimeInterval(-86_401), now: now, calendar: calendar))
    }

    /// Yesterday starts at the previous midnight, which is 23 or 25 hours back on the day after the clocks change.
    @Test func yesterdayStartsAtThePreviousMidnightEvenAroundADaylightSavingChange() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        // The clocks went forward on Sunday 9 March 2025, so that Sunday was 23 hours long.
        let monday = ny.date(from: DateComponents(year: 2025, month: 3, day: 10, hour: 14))!
        let lateSaturday = ny.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 23, minute: 30))!
        let earlySunday = ny.date(from: DateComponents(year: 2025, month: 3, day: 9, hour: 0, minute: 30))!
        #expect(!HistoryWindow.yesterday.contains(lateSaturday, now: monday, calendar: ny), "that is the day before yesterday")
        #expect(HistoryWindow.yesterday.contains(earlySunday, now: monday, calendar: ny))
    }

    @Test func downloadsCanBeClearedOnlyWhereFinishedOnesAreShown() {
        #expect(DownloadFilter.all.showsFinished && DownloadFilter.finished.showsFinished && DownloadFilter.stopped.showsFinished)
        #expect(!DownloadFilter.inProgress.showsFinished, "Clear would remove entries the viewer cannot see")
    }

    @Test func historyLoadsFurtherBackWhenAFilterNeedsIt() {
        #expect(HistoryWindow.allTime.loadLimit(searching: false) == 400)
        #expect(HistoryWindow.today.loadLimit(searching: false) > 400)
        #expect(HistoryWindow.lastWeek.loadLimit(searching: true) > 200)
        #expect(HistoryWindow.allTime.loadLimit(searching: true) == 200)
    }

    @Test func lastWeekIsTheSevenDaysUpToNow() {
        #expect(HistoryWindow.lastWeek.contains(ago(6.9 * 86_400), now: now, calendar: calendar))
        #expect(!HistoryWindow.lastWeek.contains(ago(7.1 * 86_400), now: now, calendar: calendar))
        #expect(HistoryWindow.lastWeek.contains(now, now: now, calendar: calendar))
    }

    @Test func downloadsAreSplitByWhatBecameOfThem() {
        let states: [DownloadItem.State] = [.running, .finished, .failed("offline"), .cancelled]
        #expect(states.filter(DownloadFilter.all.matches) .count == 4)
        #expect(states.filter(DownloadFilter.inProgress.matches).count == 1)
        #expect(states.filter(DownloadFilter.finished.matches).count == 1)
        #expect(states.filter(DownloadFilter.stopped.matches).count == 2, "failed and cancelled")
    }

    @Test func archivedTabsAreSplitByWhyTheyLeft() {
        func item(_ reason: ArchiveReason) -> ArchivedItem { ArchivedItem(reason: reason, spaceID: nil, items: []) }
        let all = [ArchiveReason.auto, .closed, .cleared, .imported].map(item)
        #expect(all.filter(ArchiveFilter.all.matches).count == 4)
        #expect(all.filter(ArchiveFilter.closed.matches).map(\.reason) == [.closed, .cleared], "closed by hand, one at a time or all at once")
        #expect(all.filter(ArchiveFilter.automatic.matches).map(\.reason) == [.auto])
        #expect(all.filter(ArchiveFilter.imported.matches).map(\.reason) == [.imported])
    }

    @Test func eachFilterHasANameAndTheFirstChoiceLetsEverythingThrough() {
        #expect(HistoryWindow.allCases.first == .allTime && DownloadFilter.allCases.first == .all && ArchiveFilter.allCases.first == .all)
        for title in HistoryWindow.allCases.map(\.title) + DownloadFilter.allCases.map(\.title) + ArchiveFilter.allCases.map(\.title) {
            #expect(!title.isEmpty)
        }
    }
}
