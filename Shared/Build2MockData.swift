import Foundation

enum Build2MockData {
    static func state(
        selection: MetricSelection = .all,
        at date: Date = Date(),
        calendar: Calendar = SharedConfiguration.localCalendar
    ) -> SharedWidgetState {
        let today = LocalDay(date: date, calendar: calendar)
        let snapshot = HealthSnapshot(
            steps: .value(DailyMetricValue(value: 7_842, sourceDay: today)),
            sleep: .value(sleepSession(at: date, calendar: calendar)),
            restingHeartRate: .value(DailyMetricValue(value: 61, sourceDay: today)),
            hrv: .value(DailyMetricValue(value: 48, sourceDay: today)),
            lastSuccessfulUpdate: date
        )

        return SharedWidgetState(
            selection: selection,
            content: .data(WidgetData(snapshot: snapshot, lastSyncIssue: nil)),
            permissions: .all
        )
    }

    private static func sleepSession(at date: Date, calendar: Calendar) -> SleepSession {
        let startOfToday = calendar.startOfDay(for: date)
        let candidateWake = calendar.date(
            byAdding: .minute,
            value: 8 * 60 + 2,
            to: startOfToday
        ) ?? date
        let wakeTime = candidateWake <= date
            ? candidateWake
            : (calendar.date(byAdding: .day, value: -1, to: candidateWake) ?? candidateWake)
        let bedtime = calendar.date(
            byAdding: .minute,
            value: -(5 * 60 + 41),
            to: wakeTime
        ) ?? wakeTime

        return SleepSession(
            minutesAsleep: 4 * 60 + 56,
            start: ZonedInstant(
                instant: bedtime,
                utcOffsetSeconds: calendar.timeZone.secondsFromGMT(for: bedtime)
            ),
            end: ZonedInstant(
                instant: wakeTime,
                utcOffsetSeconds: calendar.timeZone.secondsFromGMT(for: wakeTime)
            ),
            stages: .available(SleepStages(
                awakeMinutes: 45,
                lightMinutes: 3 * 60 + 27,
                remMinutes: 37,
                deepMinutes: 52
            ))
        )
    }
}
