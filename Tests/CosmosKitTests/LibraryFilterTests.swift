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

    @Test func eachFilterHasANameAndTheFirstChoiceLetsEverythingThrough() {
        #expect(HistoryWindow.allCases.first == .allTime && DownloadFilter.allCases.first == .all && TimelineKind.allCases.first == .everything)
        for title in HistoryWindow.allCases.map(\.title) + DownloadFilter.allCases.map(\.title) + TimelineKind.allCases.map(\.title) {
            #expect(!title.isEmpty)
        }
    }

    // MARK: One timeline of pages visited and tabs archived

    private func visit(_ url: String, at date: Date) -> HistoryEntry { HistoryEntry(url: URL(string: url)!, title: url, firstVisit: date, lastVisit: date) }
    private func archived(_ reason: ArchiveReason = .closed, at date: Date) -> ArchivedItem { ArchivedItem(archivedAt: date, reason: reason, spaceID: nil, items: []) }

    @Test func visitsAndArchivedTabsShareOneListNewestFirst() {
        let v1 = visit("https://a.example/", at: ago(100)), v2 = visit("https://b.example/", at: ago(5_000))
        let a1 = archived(at: ago(2_000)), a2 = archived(at: ago(9_000))
        let items = Timeline.merge(visits: [v1, v2], archived: [a1, a2], kind: .everything, period: .allTime, now: now, calendar: calendar)
        #expect(items.map(\.date) == [ago(100), ago(2_000), ago(5_000), ago(9_000)])
        #expect(items.map(\.isArchived) == [false, true, false, true])
    }

    @Test func theKindChoosesWhichOfThemShow() {
        let visits = [visit("https://a.example/", at: ago(10))], tabs = [archived(at: ago(20))]
        #expect(Timeline.merge(visits: visits, archived: tabs, kind: .visited, period: .allTime, now: now, calendar: calendar).map(\.isArchived) == [false])
        #expect(Timeline.merge(visits: visits, archived: tabs, kind: .archived, period: .allTime, now: now, calendar: calendar).map(\.isArchived) == [true])
    }

    @Test func theTimeRangeAppliesToBoth() {
        let old = 10 * 86_400.0
        let items = Timeline.merge(visits: [visit("https://a.example/", at: ago(60)), visit("https://old.example/", at: ago(old))],
                                   archived: [archived(at: ago(120)), archived(at: ago(old))], kind: .everything, period: .lastWeek, now: now, calendar: calendar)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.date >= ago(7 * 86_400) })
    }

    @Test func equalMomentsKeepAFixedOrderSoTheListDoesNotShuffle() {
        let same = ago(30)
        let visits = (0..<4).map { visit("https://v\($0).example/", at: same) }
        let tabs = (0..<3).map { _ in archived(at: same) }
        let first = Timeline.merge(visits: visits, archived: tabs, kind: .everything, period: .allTime, now: now, calendar: calendar).map(\.id)
        let second = Timeline.merge(visits: visits.reversed(), archived: tabs.reversed(), kind: .everything, period: .allTime, now: now, calendar: calendar).map(\.id)
        #expect(first == second)
        #expect(Set(first).count == 7, "no two share an id")
    }

    @Test func daysAreGroupedWithTodayAndYesterdayNamed() {
        let midnight = calendar.startOfDay(for: now)
        let items = Timeline.merge(visits: [visit("https://a.example/", at: midnight.addingTimeInterval(60))],
                                   archived: [archived(at: midnight.addingTimeInterval(-60)), archived(at: midnight.addingTimeInterval(-100_000))],
                                   kind: .everything, period: .allTime, now: now, calendar: calendar)
        let groups = Timeline.groups(items, now: now, calendar: calendar)
        #expect(groups.map(\.title).prefix(2) == ["Today", "Yesterday"])
        #expect(groups.count == 3 && groups.map(\.items.count) == [1, 1, 1])
    }

    @Test func anEmptyTimelineHasNoGroups() {
        #expect(Timeline.groups([], now: now, calendar: calendar).isEmpty)
    }
}
