import Foundation
import XCTest

final class Build2SharedStateTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    func testSelectionDecodingRequiresUniqueCanonicalOrder() throws {
        XCTAssertEqual(
            try JSONDecoder().decode(MetricSelection.self, from: Data(#"["steps","sleep","hrv"]"#.utf8)),
            MetricSelection([.steps, .sleep, .hrv])
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(MetricSelection.self, from: Data(#"[]"#.utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(MetricSelection.self, from: Data(#"["sleep","steps"]"#.utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(MetricSelection.self, from: Data(#"["steps","steps"]"#.utf8))
        )
    }

    func testSharedStateEncodingRoundTrip() throws {
        let date = try makeDate(2026, 10, 30, 12)
        let state = Build2MockData.state(
            selection: try XCTUnwrap(MetricSelection([.steps, .sleep, .hrv])),
            at: date,
            calendar: calendar
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SharedWidgetState.self, from: data)

        XCTAssertEqual(decoded, state)
    }

    func testBuild2StateWithoutPermissionsDecodesSafely() throws {
        let data = Data(#"""
        {
          "selection":["steps","sleep"],
          "content":{"unconnected":{}}
        }
        """#.utf8)
        let decoded = try JSONDecoder().decode(SharedWidgetState.self, from: data)

        XCTAssertEqual(decoded.selection, MetricSelection([.steps, .sleep]))
        XCTAssertEqual(decoded.permissions, .none)
    }

    func testStoreRoundTripAndClear() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = SharedWidgetStore(containerURL: directoryURL)
        let state = Build2MockData.state(at: try makeDate(2026, 10, 30, 12), calendar: calendar)

        XCTAssertEqual(store.load(), .initial)

        try store.save(state)
        XCTAssertEqual(store.load(), state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(
            try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true
        )

        try store.clear()
        XCTAssertEqual(store.load(), .initial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testCorruptAndUnsupportedSnapshotsFallBackToInitialState() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let store = SharedWidgetStore(containerURL: directoryURL)
        try Data("not-json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), .initial)

        try Data(#"{"schemaVersion":2,"state":{}}"#.utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), .initial)
    }

    func testTimelineIncludesEverySnapshotTransitionAndHourlyRefresh() throws {
        let now = try makeDate(2026, 10, 30, 12)
        let update = now.addingTimeInterval(-60 * 60)
        let sleepEnd = now.addingTimeInterval(-30 * 60 * 60)
        let today = LocalDay(date: now, calendar: calendar)
        let snapshot = HealthSnapshot(
            steps: .value(DailyMetricValue(value: 1, sourceDay: today)),
            sleep: .value(SleepSession(
                minutesAsleep: 480,
                start: ZonedInstant(
                    instant: sleepEnd.addingTimeInterval(-9 * 60 * 60),
                    utcOffsetSeconds: -5 * 60 * 60
                ),
                end: ZonedInstant(instant: sleepEnd, utcOffsetSeconds: -5 * 60 * 60),
                stages: .unavailable
            )),
            restingHeartRate: .value(DailyMetricValue(value: 61, sourceDay: today)),
            hrv: .value(DailyMetricValue(value: 45, sourceDay: today)),
            lastSuccessfulUpdate: update
        )
        let state = SharedWidgetState(
            selection: .all,
            content: .data(WidgetData(snapshot: snapshot, lastSyncIssue: nil))
        )

        let schedule = WidgetTimelineSchedule.make(
            state: state,
            startingAt: now,
            calendar: calendar
        )

        XCTAssertEqual(schedule.refreshDate, now.addingTimeInterval(60 * 60))
        XCTAssertEqual(schedule.items.first?.date, now)
        XCTAssertEqual(
            Array(schedule.items.dropFirst().map(\.date)),
            snapshot.transitionDates(after: now, calendar: calendar)
        )
        XCTAssertTrue(schedule.items.allSatisfy { $0.state == state })
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        )))
    }
}
