import Foundation

enum MetricKind: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
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

    static func canonicalOrder(for selection: Set<Self>) -> [Self] {
        allCases.filter(selection.contains)
    }
}

enum MetricState<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value)
    case noData
    case permissionRequired
}

extension MetricState: Codable where Value: Codable {}

struct MetricSelection: Equatable, Sendable {
    let metrics: [MetricKind]

    init?(_ metrics: some Sequence<MetricKind>) {
        let uniqueMetrics = Set(metrics)
        guard !uniqueMetrics.isEmpty, uniqueMetrics.count <= MetricKind.allCases.count else {
            return nil
        }

        self.metrics = MetricKind.canonicalOrder(for: uniqueMetrics)
    }

    static let all = MetricSelection(MetricKind.allCases)!

    func contains(_ metric: MetricKind) -> Bool {
        metrics.contains(metric)
    }
}

struct MetricPermissions: Equatable, Sendable {
    let grantedMetrics: [MetricKind]

    init(_ metrics: some Sequence<MetricKind>) {
        grantedMetrics = MetricKind.canonicalOrder(for: Set(metrics))
    }

    static let none = MetricPermissions([] as [MetricKind])
    static let all = MetricPermissions(MetricKind.allCases)

    func allows(_ metric: MetricKind) -> Bool {
        grantedMetrics.contains(metric)
    }

    var isPartial: Bool {
        !grantedMetrics.isEmpty && grantedMetrics.count < MetricKind.allCases.count
    }
}

extension MetricPermissions: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decodedMetrics = try container.decode([MetricKind].self)

        guard Set(decodedMetrics).count == decodedMetrics.count,
              MetricKind.canonicalOrder(for: Set(decodedMetrics)) == decodedMetrics else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Granted metrics must be unique and in canonical order."
            )
        }

        self.init(decodedMetrics)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(grantedMetrics)
    }
}

extension MetricSelection: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decodedMetrics = try container.decode([MetricKind].self)

        guard Set(decodedMetrics).count == decodedMetrics.count,
              let selection = MetricSelection(decodedMetrics),
              selection.metrics == decodedMetrics else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Metric selection must contain 1–4 unique metrics in canonical order."
            )
        }

        self = selection
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(metrics)
    }
}

struct LocalDay: Codable, Equatable, Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1
        month = components.month ?? 1
        day = components.day ?? 1
    }

    func date(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}

struct DailyMetricValue: Codable, Equatable, Sendable {
    let value: Int
    let sourceDay: LocalDay
}

struct ZonedInstant: Codable, Equatable, Sendable {
    let instant: Date
    let utcOffsetSeconds: Int
}

enum SleepStageKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case awake
    case light
    case rem
    case deep

    var id: Self { self }

    var title: String {
        rawValue.capitalized
    }
}

struct SleepStages: Codable, Equatable, Sendable {
    let awakeMinutes: Int?
    let lightMinutes: Int?
    let remMinutes: Int?
    let deepMinutes: Int?

    func minutes(for stage: SleepStageKind) -> Int? {
        switch stage {
        case .awake: awakeMinutes
        case .light: lightMinutes
        case .rem: remMinutes
        case .deep: deepMinutes
        }
    }
}

enum SleepStageState: Codable, Equatable, Sendable {
    case available(SleepStages)
    case processing
    case unavailable
}

struct SleepSession: Codable, Equatable, Sendable {
    let minutesAsleep: Int
    let start: ZonedInstant
    let end: ZonedInstant
    let stages: SleepStageState

    var wakeDay: LocalDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: end.utcOffsetSeconds) ?? TimeZone(secondsFromGMT: 0)!
        return LocalDay(date: end.instant, calendar: calendar)
    }
}

struct HealthSnapshot: Codable, Equatable, Sendable {
    let steps: MetricState<DailyMetricValue>
    let sleep: MetricState<SleepSession>
    let restingHeartRate: MetricState<DailyMetricValue>
    let hrv: MetricState<DailyMetricValue>
    let lastSuccessfulUpdate: Date

    func applyingPermissions(_ permissions: MetricPermissions) -> Self {
        Self(steps: permissions.allows(.steps) ? steps : .permissionRequired,
             sleep: permissions.allows(.sleep) ? sleep : .permissionRequired,
             restingHeartRate: permissions.allows(.restingHeartRate) ? restingHeartRate : .permissionRequired,
             hrv: permissions.allows(.hrv) ? hrv : .permissionRequired,
             lastSuccessfulUpdate: lastSuccessfulUpdate)
    }

    func resolved(at evaluationDate: Date, calendar: Calendar) -> ResolvedHealthSnapshot {
        ResolvedHealthSnapshot(
            steps: resolveSteps(at: evaluationDate, calendar: calendar),
            sleep: resolveSleep(at: evaluationDate),
            restingHeartRate: resolveRecentDailyMetric(
                restingHeartRate,
                at: evaluationDate,
                calendar: calendar
            ),
            hrv: resolveRecentDailyMetric(hrv, at: evaluationDate, calendar: calendar),
            lastSuccessfulUpdate: lastSuccessfulUpdate,
            isStale: evaluationDate.timeIntervalSince(lastSuccessfulUpdate) > Self.staleInterval
        )
    }

    func transitionDates(after date: Date, calendar: Calendar) -> [Date] {
        var transitions = Set<Date>()

        addTransition(lastSuccessfulUpdate.addingTimeInterval(Self.staleInterval + 1), after: date, to: &transitions)

        if case .value = steps,
           let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) {
            addTransition(midnight, after: date, to: &transitions)
        }

        if case let .value(session) = sleep {
            addTransition(
                session.end.instant.addingTimeInterval(Self.sleepValidityInterval + 1),
                after: date,
                to: &transitions
            )
        }

        addDailyMetricExpiration(restingHeartRate, after: date, calendar: calendar, to: &transitions)
        addDailyMetricExpiration(hrv, after: date, calendar: calendar, to: &transitions)

        return transitions.sorted()
    }

    private static let staleInterval: TimeInterval = 6 * 60 * 60
    private static let sleepValidityInterval: TimeInterval = 36 * 60 * 60

    private func resolveSteps(at date: Date, calendar: Calendar) -> MetricState<DailyMetricValue> {
        guard case let .value(value) = steps else { return steps }
        return value.sourceDay == LocalDay(date: date, calendar: calendar) ? .value(value) : .noData
    }

    private func resolveSleep(at date: Date) -> MetricState<SleepSession> {
        guard case let .value(session) = sleep else { return sleep }
        let age = date.timeIntervalSince(session.end.instant)
        return (0...Self.sleepValidityInterval).contains(age) ? .value(session) : .noData
    }

    private func resolveRecentDailyMetric(
        _ metric: MetricState<DailyMetricValue>,
        at date: Date,
        calendar: Calendar
    ) -> MetricState<DailyMetricValue> {
        guard case let .value(value) = metric,
              let sourceDate = value.sourceDay.date(in: calendar),
              let evaluationDay = LocalDay(date: date, calendar: calendar).date(in: calendar),
              let ageInDays = calendar.dateComponents([.day], from: sourceDate, to: evaluationDay).day,
              (0...3).contains(ageInDays) else {
            if case .value = metric { return .noData }
            return metric
        }

        return .value(value)
    }

    private func addDailyMetricExpiration(
        _ metric: MetricState<DailyMetricValue>,
        after date: Date,
        calendar: Calendar,
        to transitions: inout Set<Date>
    ) {
        guard case let .value(value) = metric,
              let sourceDate = value.sourceDay.date(in: calendar),
              let expiration = calendar.date(byAdding: .day, value: 4, to: sourceDate) else {
            return
        }

        addTransition(expiration, after: date, to: &transitions)
    }

    private func addTransition(_ transition: Date, after date: Date, to transitions: inout Set<Date>) {
        if transition > date {
            transitions.insert(transition)
        }
    }
}

struct ResolvedHealthSnapshot: Equatable, Sendable {
    let steps: MetricState<DailyMetricValue>
    let sleep: MetricState<SleepSession>
    let restingHeartRate: MetricState<DailyMetricValue>
    let hrv: MetricState<DailyMetricValue>
    let lastSuccessfulUpdate: Date
    let isStale: Bool
}

enum SyncIssue: Codable, Equatable, Sendable {
    case offline
    case updateFailed
    case reconnectRequired
}

struct WidgetData: Codable, Equatable, Sendable {
    let snapshot: HealthSnapshot
    let lastSyncIssue: SyncIssue?
}

enum WidgetContent: Codable, Equatable, Sendable {
    case unconnected
    case accountNotLinked
    case initialSyncFailed
    case data(WidgetData)
}

struct SyncMetadata: Codable, Equatable, Sendable {
    var failureCount = 0
    var nextAttempt: Date?
    var lastSyncedSelection: MetricSelection?
    var reconnectRequired = false
    static let initial = SyncMetadata()
}

struct SharedWidgetState: Codable, Equatable, Sendable {
    let selection: MetricSelection
    let content: WidgetContent
    let permissions: MetricPermissions
    // Set only after users/me/identity succeeds; sample/Build #2 state stays unverified.
    let hasVerifiedIdentity: Bool
    let sync: SyncMetadata
    let connectionID: UUID?

    init(
        selection: MetricSelection,
        content: WidgetContent,
        permissions: MetricPermissions = .none,
        hasVerifiedIdentity: Bool = false,
        sync: SyncMetadata = .initial,
        connectionID: UUID? = nil
    ) {
        self.selection = selection
        self.content = content
        self.permissions = permissions
        self.hasVerifiedIdentity = hasVerifiedIdentity
        self.sync = sync
        self.connectionID = hasVerifiedIdentity ? (connectionID ?? UUID()) : nil
    }

    func replacing(selection: MetricSelection? = nil, content: WidgetContent? = nil,
                   permissions: MetricPermissions? = nil, sync: SyncMetadata? = nil) -> Self {
        Self(selection: selection ?? self.selection, content: content ?? self.content,
             permissions: permissions ?? self.permissions, hasVerifiedIdentity: hasVerifiedIdentity,
             sync: sync ?? self.sync, connectionID: connectionID)
    }

    static let initial = SharedWidgetState(
        selection: .all,
        content: .unconnected,
        permissions: .none
    )

    private enum CodingKeys: String, CodingKey {
        case selection
        case content
        case permissions
        case hasVerifiedIdentity
        case sync
        case connectionID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selection = try container.decode(MetricSelection.self, forKey: .selection)
        content = try container.decode(WidgetContent.self, forKey: .content)
        permissions = try container.decodeIfPresent(
            MetricPermissions.self,
            forKey: .permissions
        ) ?? .none
        hasVerifiedIdentity = try container.decodeIfPresent(Bool.self, forKey: .hasVerifiedIdentity) ?? false
        sync = try container.decodeIfPresent(SyncMetadata.self, forKey: .sync) ?? .initial
        connectionID = try container.decodeIfPresent(UUID.self, forKey: .connectionID)
    }
}
