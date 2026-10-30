import Foundation
import WidgetKit

enum MetricKind: String, CaseIterable, Identifiable {
    case steps
    case sleep
    case restingHeartRate
    case hrv

    var id: Self { self }

    var title: String {
        switch self {
        case .steps: "Steps"
        case .sleep: "Sleep"
        case .restingHeartRate: "Resting Heart Rate"
        case .hrv: "HRV"
        }
    }

    var symbolName: String {
        switch self {
        case .steps: "figure.walk"
        case .sleep: "moon.stars.fill"
        case .restingHeartRate: "heart.fill"
        case .hrv: "waveform.path.ecg"
        }
    }
}

enum ReadingStatus: Equatable {
    case available
    case missing(message: String)
    case permissionRequired
}

struct MetricReading: Equatable {
    let kind: MetricKind
    let value: String?
    let unit: String
    let detail: String
    let status: ReadingStatus

    static func available(
        _ kind: MetricKind,
        value: String,
        unit: String,
        detail: String = "Today"
    ) -> Self {
        Self(kind: kind, value: value, unit: unit, detail: detail, status: .available)
    }

    static func missing(_ kind: MetricKind, message: String = "No Recent Data") -> Self {
        Self(kind: kind, value: nil, unit: "", detail: message, status: .missing(message: message))
    }

    static func permissionRequired(_ kind: MetricKind) -> Self {
        Self(
            kind: kind,
            value: nil,
            unit: "",
            detail: "Permission Required",
            status: .permissionRequired
        )
    }
}

enum SleepStageKind: String, CaseIterable, Identifiable {
    case awake
    case light
    case rem
    case deep

    var id: Self { self }

    var title: String {
        rawValue.capitalized
    }
}

struct SleepStage: Identifiable, Equatable {
    let kind: SleepStageKind
    let minutes: Int

    var id: SleepStageKind { kind }
}

enum SleepStageStatus: Equatable {
    case available
    case processing
    case unavailable
}

struct SleepSnapshot: Equatable {
    let totalAsleepMinutes: Int
    let bedtime: Date
    let wakeTime: Date
    let stages: [SleepStage]
    let stageStatus: SleepStageStatus
}

enum WidgetSyncStatus: Equatable {
    case current
    case stale
    case offline
    case updateFailed
    case reconnectRequired

    var title: String? {
        switch self {
        case .current: nil
        case .stale: "Stale"
        case .offline: "Offline"
        case .updateFailed: "Update Failed"
        case .reconnectRequired: "Reconnect in App"
        }
    }

    var symbolName: String {
        switch self {
        case .current: "checkmark.circle.fill"
        case .stale: "clock.badge.exclamationmark.fill"
        case .offline: "wifi.slash"
        case .updateFailed: "exclamationmark.triangle.fill"
        case .reconnectRequired: "person.crop.circle.badge.exclamationmark.fill"
        }
    }
}

struct FitbitWidgetEntry: TimelineEntry {
    let date: Date
    let selectedMetrics: [MetricKind]
    let readings: [MetricReading]
    let sleep: SleepSnapshot?
    let syncStatus: WidgetSyncStatus
    let lastSuccessfulUpdate: Date?
    let initialMessage: String?

    var isInitial: Bool { initialMessage != nil }

    func reading(for kind: MetricKind) -> MetricReading? {
        readings.first { $0.kind == kind }
    }
}

extension FitbitWidgetEntry {
    static let normal = makeEntry()

    static let missingMetric = makeEntry(
        readings: [
            .available(.steps, value: "7,842", unit: "steps"),
            .available(.restingHeartRate, value: "61", unit: "bpm"),
            .missing(.hrv)
        ]
    )

    static let stale = makeEntry(
        syncStatus: .stale,
        updatedMinutesAgo: 8 * 60
    )

    static let offline = makeEntry(
        syncStatus: .offline,
        updatedMinutesAgo: 46
    )

    static let updateFailed = makeEntry(
        syncStatus: .updateFailed,
        updatedMinutesAgo: 128
    )

    static let reconnectRequired = makeEntry(
        syncStatus: .reconnectRequired,
        updatedMinutesAgo: 132
    )

    static let permissionRequired = makeEntry(
        readings: [
            .available(.steps, value: "7,842", unit: "steps"),
            .available(.restingHeartRate, value: "61", unit: "bpm"),
            .permissionRequired(.hrv)
        ]
    )

    static let missingSleep = makeEntry(sleep: nil)

    static let sleepStagesProcessing = makeEntry(
        sleep: makeSleep(stageStatus: .processing)
    )

    static let sleepStagesUnavailable = makeEntry(
        sleep: makeSleep(stageStatus: .unavailable)
    )

    static let initial = FitbitWidgetEntry(
        date: Date(),
        selectedMetrics: MetricKind.allCases,
        readings: [],
        sleep: nil,
        syncStatus: .current,
        lastSuccessfulUpdate: nil,
        initialMessage: "Connect Google Health in App"
    )

    static let sleepAndSteps = makeEntry(
        selectedMetrics: [.steps, .sleep]
    )

    static let compactOnly = makeEntry(
        selectedMetrics: [.steps, .restingHeartRate, .hrv]
    )

    static let sleepOnly = makeEntry(
        selectedMetrics: [.sleep]
    )

    private static func makeEntry(
        selectedMetrics: [MetricKind] = MetricKind.allCases,
        readings: [MetricReading] = defaultReadings,
        sleep: SleepSnapshot? = defaultSleep,
        syncStatus: WidgetSyncStatus = .current,
        updatedMinutesAgo: Int = 24
    ) -> FitbitWidgetEntry {
        FitbitWidgetEntry(
            date: Date(),
            selectedMetrics: MetricKind.allCases.filter { selectedMetrics.contains($0) },
            readings: readings,
            sleep: sleep,
            syncStatus: syncStatus,
            lastSuccessfulUpdate: Calendar.current.date(
                byAdding: .minute,
                value: -updatedMinutesAgo,
                to: Date()
            ),
            initialMessage: nil
        )
    }

    private static let defaultReadings: [MetricReading] = [
        .available(.steps, value: "7,842", unit: "steps"),
        .available(.restingHeartRate, value: "61", unit: "bpm"),
        .available(.hrv, value: "48", unit: "ms")
    ]

    private static var defaultSleep: SleepSnapshot {
        makeSleep(stageStatus: .available)
    }

    private static func makeSleep(stageStatus: SleepStageStatus) -> SleepSnapshot {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let candidateWake = calendar.date(
            byAdding: .minute,
            value: 8 * 60 + 2,
            to: startOfToday
        ) ?? now
        let wakeTime = candidateWake <= now
            ? candidateWake
            : (calendar.date(byAdding: .day, value: -1, to: candidateWake) ?? candidateWake)
        let bedtime = calendar.date(
            byAdding: .minute,
            value: -(5 * 60 + 41),
            to: wakeTime
        ) ?? wakeTime

        return SleepSnapshot(
            totalAsleepMinutes: 4 * 60 + 56,
            bedtime: bedtime,
            wakeTime: wakeTime,
            stages: [
                SleepStage(kind: .awake, minutes: 45),
                SleepStage(kind: .light, minutes: 3 * 60 + 27),
                SleepStage(kind: .rem, minutes: 37),
                SleepStage(kind: .deep, minutes: 52)
            ],
            stageStatus: stageStatus
        )
    }
}
