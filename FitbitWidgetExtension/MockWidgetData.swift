import Foundation
import WidgetKit

struct FitbitWidgetEntry: TimelineEntry, Sendable {
    let date: Date
    let state: SharedWidgetState
}

extension FitbitWidgetEntry {
    static var normal: Self { makeEntry() }

    static var missingMetric: Self {
        makeEntry(hrv: .noData)
    }

    static var stale: Self {
        makeEntry(updatedMinutesAgo: 8 * 60)
    }

    static var offline: Self {
        makeEntry(lastSyncIssue: .offline, updatedMinutesAgo: 46)
    }

    static var offlineAndStale: Self {
        makeEntry(lastSyncIssue: .offline, updatedMinutesAgo: 8 * 60)
    }

    static var updateFailed: Self {
        makeEntry(lastSyncIssue: .updateFailed, updatedMinutesAgo: 128)
    }

    static var reconnectRequired: Self {
        makeEntry(lastSyncIssue: .reconnectRequired, updatedMinutesAgo: 132)
    }

    static var permissionRequired: Self {
        makeEntry(hrv: .permissionRequired)
    }

    static var sleepPermissionRequired: Self {
        makeEntry(sleep: .permissionRequired)
    }

    static var missingSleep: Self {
        makeEntry(sleep: .noData)
    }

    static var sleepStagesProcessing: Self {
        makeEntry(sleep: .value(makeSleep(stageState: .processing)))
    }

    static var sleepStagesUnavailable: Self {
        makeEntry(sleep: .value(makeSleep(stageState: .unavailable)))
    }

    static var zeroSteps: Self {
        let now = Date()
        return makeEntry(
            date: now,
            steps: .value(DailyMetricValue(
                value: 0,
                sourceDay: LocalDay(date: now, calendar: SharedConfiguration.localCalendar)
            ))
        )
    }

    static var unconnected: Self {
        Self(date: Date(), state: .initial)
    }

    static var accountNotLinked: Self {
        Self(
            date: Date(),
            state: SharedWidgetState(selection: .all, content: .accountNotLinked)
        )
    }

    static var initialSyncFailed: Self {
        Self(
            date: Date(),
            state: SharedWidgetState(selection: .all, content: .initialSyncFailed)
        )
    }

    static var sleepAndSteps: Self {
        makeEntry(selection: [.steps, .sleep])
    }

    static var compactOnly: Self {
        makeEntry(selection: [.steps, .restingHeartRate, .hrv])
    }

    static var sleepOnly: Self {
        makeEntry(selection: [.sleep])
    }

    static var worstCase: Self {
        let now = Date()
        let calendar = SharedConfiguration.localCalendar
        let priorDay = calendar.date(byAdding: .day, value: -3, to: now) ?? now

        return makeEntry(
            date: now,
            steps: .value(DailyMetricValue(
                value: 23_456,
                sourceDay: LocalDay(date: now, calendar: calendar)
            )),
            sleep: .value(makeSleep(
                minutesAsleep: 10 * 60 + 45,
                stageState: .available(SleepStages(
                    awakeMinutes: 0,
                    lightMinutes: 6 * 60 + 20,
                    remMinutes: 2 * 60 + 15,
                    deepMinutes: 2 * 60 + 10
                )),
                referenceDate: now
            )),
            restingHeartRate: .value(DailyMetricValue(
                value: 112,
                sourceDay: LocalDay(date: priorDay, calendar: calendar)
            )),
            hrv: .value(DailyMetricValue(
                value: 123,
                sourceDay: LocalDay(date: priorDay, calendar: calendar)
            ))
        )
    }

    private static func makeEntry(
        date: Date = Date(),
        selection: Set<MetricKind> = Set(MetricKind.allCases),
        steps: MetricState<DailyMetricValue>? = nil,
        sleep: MetricState<SleepSession>? = nil,
        restingHeartRate: MetricState<DailyMetricValue>? = nil,
        hrv: MetricState<DailyMetricValue>? = nil,
        lastSyncIssue: SyncIssue? = nil,
        updatedMinutesAgo: Int = 24
    ) -> Self {
        let calendar = SharedConfiguration.localCalendar
        let today = LocalDay(date: date, calendar: calendar)
        let snapshot = HealthSnapshot(
            steps: steps ?? .value(DailyMetricValue(value: 7_842, sourceDay: today)),
            sleep: sleep ?? .value(makeSleep(referenceDate: date)),
            restingHeartRate: restingHeartRate ?? .value(DailyMetricValue(value: 61, sourceDay: today)),
            hrv: hrv ?? .value(DailyMetricValue(value: 48, sourceDay: today)),
            lastSuccessfulUpdate: calendar.date(
                byAdding: .minute,
                value: -updatedMinutesAgo,
                to: date
            ) ?? date
        )

        return Self(
            date: date,
            state: SharedWidgetState(
                selection: MetricSelection(selection) ?? .all,
                content: .data(WidgetData(
                    snapshot: snapshot,
                    lastSyncIssue: lastSyncIssue
                )),
                permissions: .all
            )
        )
    }

    private static func makeSleep(
        minutesAsleep: Int = 4 * 60 + 56,
        stageState: SleepStageState = .available(SleepStages(
            awakeMinutes: 45,
            lightMinutes: 3 * 60 + 27,
            remMinutes: 37,
            deepMinutes: 52
        )),
        referenceDate: Date = Date()
    ) -> SleepSession {
        let calendar = SharedConfiguration.localCalendar
        let startOfToday = calendar.startOfDay(for: referenceDate)
        let candidateWake = calendar.date(
            byAdding: .minute,
            value: 8 * 60 + 2,
            to: startOfToday
        ) ?? referenceDate
        let wakeTime = candidateWake <= referenceDate
            ? candidateWake
            : (calendar.date(byAdding: .day, value: -1, to: candidateWake) ?? candidateWake)
        let bedtime = calendar.date(
            byAdding: .minute,
            value: -(minutesAsleep + 45),
            to: wakeTime
        ) ?? wakeTime

        return SleepSession(
            minutesAsleep: minutesAsleep,
            start: ZonedInstant(
                instant: bedtime,
                utcOffsetSeconds: calendar.timeZone.secondsFromGMT(for: bedtime)
            ),
            end: ZonedInstant(
                instant: wakeTime,
                utcOffsetSeconds: calendar.timeZone.secondsFromGMT(for: wakeTime)
            ),
            stages: stageState
        )
    }
}
