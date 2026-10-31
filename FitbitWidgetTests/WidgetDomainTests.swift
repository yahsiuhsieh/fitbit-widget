import Foundation
import XCTest

final class WidgetDomainTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    func testStaleIsDerivedAfterSixHoursAndCanCoexistWithOffline() throws {
        let update = try date(2026, 10, 30, 8)
        let snapshot = makeSnapshot(lastSuccessfulUpdate: update)
        let issue = SyncIssue.offline

        XCTAssertFalse(snapshot.resolved(at: update.addingTimeInterval(6 * 60 * 60), calendar: calendar).isStale)
        XCTAssertTrue(snapshot.resolved(at: update.addingTimeInterval(6 * 60 * 60 + 1), calendar: calendar).isStale)
        XCTAssertEqual(issue, .offline)
    }

    func testStepsExpireAtLocalMidnightButZeroRemainsDataBeforeMidnight() throws {
        let sourceDate = try date(2026, 10, 30, 12)
        let snapshot = makeSnapshot(
            steps: .value(DailyMetricValue(value: 0, sourceDay: LocalDay(date: sourceDate, calendar: calendar)))
        )

        let beforeMidnight = try date(2026, 10, 30, 23, 59)
        let atMidnight = try date(2026, 10, 31, 0)

        XCTAssertEqual(
            snapshot.resolved(at: beforeMidnight, calendar: calendar).steps,
            .value(DailyMetricValue(value: 0, sourceDay: LocalDay(date: sourceDate, calendar: calendar)))
        )
        XCTAssertEqual(snapshot.resolved(at: atMidnight, calendar: calendar).steps, .noData)
        XCTAssertTrue(snapshot.transitionDates(after: beforeMidnight, calendar: calendar).contains(atMidnight))
    }

    func testSleepExpiresAfterThirtySixHours() throws {
        let end = try date(2026, 10, 29, 8)
        let session = SleepSession(
            minutesAsleep: 480,
            start: ZonedInstant(instant: end.addingTimeInterval(-9 * 60 * 60), utcOffsetSeconds: -5 * 60 * 60),
            end: ZonedInstant(instant: end, utcOffsetSeconds: -5 * 60 * 60),
            stages: .processing
        )
        let snapshot = makeSnapshot(sleep: .value(session))

        XCTAssertEqual(snapshot.resolved(at: end.addingTimeInterval(36 * 60 * 60), calendar: calendar).sleep, .value(session))
        XCTAssertEqual(snapshot.resolved(at: end.addingTimeInterval(36 * 60 * 60 + 1), calendar: calendar).sleep, .noData)
    }

    func testDailyMetricsAcceptTodayAndThreePrecedingDaysOnly() throws {
        let evaluationDate = try date(2026, 10, 30, 12)

        for age in 0...3 {
            let sourceDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -age, to: evaluationDate))
            let value = DailyMetricValue(value: 61, sourceDay: LocalDay(date: sourceDate, calendar: calendar))
            let resolved = makeSnapshot(restingHeartRate: .value(value))
                .resolved(at: evaluationDate, calendar: calendar)
            XCTAssertEqual(resolved.restingHeartRate, .value(value))
        }

        let expiredDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -4, to: evaluationDate))
        let expired = DailyMetricValue(value: 61, sourceDay: LocalDay(date: expiredDate, calendar: calendar))
        XCTAssertEqual(
            makeSnapshot(restingHeartRate: .value(expired))
                .resolved(at: evaluationDate, calendar: calendar)
                .restingHeartRate,
            .noData
        )
    }

    func testMetricSelectionAlwaysUsesCanonicalOrder() {
        let selection = MetricSelection([.hrv, .steps, .sleep])

        XCTAssertEqual(selection?.metrics, [.steps, .sleep, .hrv])
        XCTAssertNil(MetricSelection([]))
    }

    func testTransitionDatesCoverAllTimeDerivedChanges() throws {
        let now = try date(2026, 10, 30, 12)
        let update = now.addingTimeInterval(-60 * 60)
        let sleepEnd = now.addingTimeInterval(-30 * 60 * 60)
        let today = LocalDay(date: now, calendar: calendar)
        let snapshot = makeSnapshot(
            steps: .value(DailyMetricValue(value: 1, sourceDay: today)),
            sleep: .value(SleepSession(
                minutesAsleep: 480,
                start: ZonedInstant(instant: sleepEnd.addingTimeInterval(-9 * 60 * 60), utcOffsetSeconds: -5 * 60 * 60),
                end: ZonedInstant(instant: sleepEnd, utcOffsetSeconds: -5 * 60 * 60),
                stages: .unavailable
            )),
            restingHeartRate: .value(DailyMetricValue(value: 61, sourceDay: today)),
            lastSuccessfulUpdate: update
        )

        let transitions = snapshot.transitionDates(after: now, calendar: calendar)
        let midnight = try date(2026, 10, 31, 0)
        let sleepExpiration = sleepEnd.addingTimeInterval(36 * 60 * 60 + 1)
        let staleTransition = update.addingTimeInterval(6 * 60 * 60 + 1)
        let dailyExpiration = try date(2026, 11, 3, 0)

        XCTAssertEqual(transitions, [
            staleTransition,
            sleepExpiration,
            midnight,
            dailyExpiration
        ].sorted())
    }

    private func makeSnapshot(
        steps: MetricState<DailyMetricValue> = .noData,
        sleep: MetricState<SleepSession> = .noData,
        restingHeartRate: MetricState<DailyMetricValue> = .noData,
        hrv: MetricState<DailyMetricValue> = .noData,
        lastSuccessfulUpdate: Date = .distantPast
    ) -> HealthSnapshot {
        HealthSnapshot(
            steps: steps,
            sleep: sleep,
            restingHeartRate: restingHeartRate,
            hrv: hrv,
            lastSuccessfulUpdate: lastSuccessfulUpdate
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int = 0
    ) throws -> Date {
        try XCTUnwrap(
            calendar.date(from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            ))
        )
    }
}
