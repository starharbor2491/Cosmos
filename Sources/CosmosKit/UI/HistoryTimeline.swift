import Foundation
import CosmosCore

/// One entry of the History section's list: a page that was visited, or a tab that left the sidebar for the Archive.
struct TimelineItem: Identifiable {
    enum Payload {
        case visit(HistoryEntry)
        case archived(ArchivedItem)
    }

    let payload: Payload

    var date: Date {
        switch payload {
        case .visit(let entry): entry.lastVisit
        case .archived(let item): item.archivedAt
        }
    }

    var id: String {
        switch payload {
        case .visit(let entry): "visit:\(entry.id)"
        case .archived(let item): "archived:\(item.id)"
        }
    }

    var isArchived: Bool { if case .archived = payload { true } else { false } }
}

/// What the History section lists and how it is cut into days. Pure, so it can be tested.
enum Timeline {
    /// Visits and archived tabs in one list, newest first, narrowed by the kind and the time range. Entries from the same
    /// moment keep a fixed order, so the list does not shuffle when it reloads.
    static func merge(visits: [HistoryEntry], archived: [ArchivedItem], kind: TimelineKind, period: HistoryWindow,
                      now: Date = Date(), calendar: Calendar = .current) -> [TimelineItem] {
        var items: [TimelineItem] = []
        if kind != .archived { items += visits.map { TimelineItem(payload: .visit($0)) } }
        if kind != .visited { items += archived.map { TimelineItem(payload: .archived($0)) } }
        return items
            .filter { period.contains($0.date, now: now, calendar: calendar) }
            .sorted { ($0.date, $1.id) > ($1.date, $0.id) }
    }

    /// The list cut into days, each named: "Today", "Yesterday", or the date in full.
    static func groups(_ items: [TimelineItem], now: Date = Date(), calendar: Calendar = .current) -> [(title: String, items: [TimelineItem])] {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateStyle = .full
        format.timeStyle = .none
        var out: [(title: String, items: [TimelineItem])] = []
        for item in items {
            let title: String
            if calendar.isDate(item.date, inSameDayAs: now) { title = "Today" }
            else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(item.date, inSameDayAs: yesterday) { title = "Yesterday" }
            else { title = format.string(from: item.date) }
            if let last = out.indices.last, out[last].title == title { out[last].items.append(item) } else { out.append((title, [item])) }
        }
        return out
    }
}
