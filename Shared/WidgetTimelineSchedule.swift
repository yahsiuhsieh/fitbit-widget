import Foundation

struct WidgetTimelineItem: Equatable, Sendable {
    let date: Date
    let state: SharedWidgetState
}

struct WidgetTimelineSchedule: Equatable, Sendable {
    static let refreshInterval: TimeInterval = 60 * 60

    let items: [WidgetTimelineItem]
    let refreshDate: Date

    static func make(
        state: SharedWidgetState,
        startingAt date: Date,
        calendar: Calendar
    ) -> Self {
        var entryDates = Set([date])

        if case let .data(data) = state.content {
            entryDates.formUnion(data.snapshot.transitionDates(after: date, calendar: calendar))
            if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) {
                entryDates.insert(midnight)
            }
        }

        let refresh: Date
        if state.sync.reconnectRequired {
            refresh = date.addingTimeInterval(refreshInterval)
        } else if let retry = state.sync.nextAttempt, retry > date {
            refresh = max(date.addingTimeInterval(300), retry)
        } else if case let .data(data) = state.content, data.lastSyncIssue != nil {
            refresh = date.addingTimeInterval(300)
        } else {
            refresh = date.addingTimeInterval(refreshInterval)
        }
        return Self(
            items: entryDates.sorted().map { WidgetTimelineItem(date: $0, state: state) },
            refreshDate: refresh
        )
    }
}
