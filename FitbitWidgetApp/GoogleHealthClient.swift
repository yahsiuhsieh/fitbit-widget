import Foundation

enum GoogleHealthClientError: Error, Equatable {
    case accountNotLinked
    case missingOAuthScope
    case authenticationRequired
    case invalidResponse
    case requestFailed
    case offline
    case retryable(retryAfter: TimeInterval?)
}

struct GoogleHealthIdentity: Equatable, Sendable {
    let healthUserID: String
}

struct GoogleHealthClient: Sendable {
    static let googleSources = "users/me/dataSourceFamilies/google-sources"

    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, session: URLSession = GoogleHealthHTTP.makeSession()) {
        self.baseURL = baseURL
        self.session = session
    }

    func identity(accessToken: String) async throws -> GoogleHealthIdentity {
        let response: IdentityResponse = try await get(
            path: "users/me/identity",
            accessToken: accessToken
        )
        guard (1...63).contains(response.healthUserId.count),
              response.healthUserId.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { throw GoogleHealthClientError.invalidResponse }
        return GoogleHealthIdentity(healthUserID: response.healthUserId)
    }

    func steps(
        for day: LocalDay,
        calendar: Calendar,
        accessToken: String
    ) async throws -> MetricState<DailyMetricValue> {
        guard let start = day.date(in: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw GoogleHealthClientError.invalidResponse
        }

        let body = DailyRollupRequest(
            range: CivilRange(
                start: CivilDateTime(date: day, time: CivilTime()),
                end: CivilDateTime(date: LocalDay(date: end, calendar: calendar), time: CivilTime())
            ),
            windowSizeDays: 1,
            dataSourceFamily: Self.googleSources
        )
        let response: DailyRollupResponse = try await post(
            path: "users/me/dataTypes/steps/dataPoints:dailyRollUp",
            body: body,
            accessToken: accessToken
        )
        return try GoogleHealthMapper.steps(from: response, expectedDay: day)
    }

    func sleep(
        at evaluationDate: Date,
        calendar: Calendar,
        accessToken: String
    ) async throws -> MetricState<SleepSession> {
        let lowerDate = evaluationDate.addingTimeInterval(-36 * 60 * 60)
        let formatter = ISO8601DateFormatter()
        let filter = "sleep.interval.end_time >= \"\(formatter.string(from: lowerDate))\""
        let response = try await reconciled(
            path: "users/me/dataTypes/sleep/dataPoints:reconcile",
            queryItems: [
                URLQueryItem(name: "filter", value: filter),
                URLQueryItem(name: "dataSourceFamily", value: Self.googleSources),
                URLQueryItem(name: "pageSize", value: "25")
            ],
            accessToken: accessToken
        )
        guard response.dataPoints.allSatisfy({ $0.sleep != nil }) else {
            throw GoogleHealthClientError.invalidResponse
        }
        return try GoogleHealthMapper.sleep(
            from: response,
            at: evaluationDate,
            calendar: calendar
        )
    }

    func restingHeartRate(
        at evaluationDate: Date,
        calendar: Calendar,
        accessToken: String
    ) async throws -> MetricState<DailyMetricValue> {
        let response = try await recentDailyData(
            dataType: "daily-resting-heart-rate",
            filterName: "daily_resting_heart_rate",
            evaluationDate: evaluationDate,
            calendar: calendar,
            accessToken: accessToken
        )
        guard response.dataPoints.allSatisfy({ $0.dailyRestingHeartRate != nil }) else {
            throw GoogleHealthClientError.invalidResponse
        }
        return try GoogleHealthMapper.restingHeartRate(
            from: response,
            at: evaluationDate,
            calendar: calendar
        )
    }

    func hrv(
        at evaluationDate: Date,
        calendar: Calendar,
        accessToken: String
    ) async throws -> MetricState<DailyMetricValue> {
        let response = try await recentDailyData(
            dataType: "daily-heart-rate-variability",
            filterName: "daily_heart_rate_variability",
            evaluationDate: evaluationDate,
            calendar: calendar,
            accessToken: accessToken
        )
        guard response.dataPoints.allSatisfy({ $0.dailyHeartRateVariability != nil }) else {
            throw GoogleHealthClientError.invalidResponse
        }
        return try GoogleHealthMapper.hrv(
            from: response,
            at: evaluationDate,
            calendar: calendar
        )
    }

    private func recentDailyData(
        dataType: String,
        filterName: String,
        evaluationDate: Date,
        calendar: Calendar,
        accessToken: String
    ) async throws -> DataPointsResponse {
        guard let lowerDate = calendar.date(byAdding: .day, value: -3, to: evaluationDate),
              let upperDate = calendar.date(byAdding: .day, value: 1, to: evaluationDate) else {
            throw GoogleHealthClientError.invalidResponse
        }
        let lowerDay = LocalDay(date: lowerDate, calendar: calendar)
        let upperDay = LocalDay(date: upperDate, calendar: calendar)
        let filter = "\(filterName).date >= \"\(lowerDay.apiDate)\" AND \(filterName).date < \"\(upperDay.apiDate)\""

        return try await reconciled(
            path: "users/me/dataTypes/\(dataType)/dataPoints:reconcile",
            queryItems: [
                URLQueryItem(name: "filter", value: filter),
                URLQueryItem(name: "dataSourceFamily", value: Self.googleSources)
            ],
            accessToken: accessToken
        )
    }

    private func reconciled(path: String, queryItems: [URLQueryItem], accessToken: String) async throws -> DataPointsResponse {
        var points: [GoogleHealthDataPoint] = []
        var pageToken: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            var query = queryItems
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: DataPointsResponse = try await get(path: path, queryItems: query, accessToken: accessToken)
            points.append(contentsOf: page.dataPoints)
            pageToken = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            if let pageToken {
                guard seen.insert(pageToken).inserted, seen.count < 100 else {
                    throw GoogleHealthClientError.invalidResponse
                }
            }
        } while pageToken != nil
        return DataPointsResponse(dataPoints: points)
    }

    private func get<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        accessToken: String
    ) async throws -> Response {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw GoogleHealthClientError.invalidResponse
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw GoogleHealthClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        accessToken: String
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? URLError,
               [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code) {
                throw GoogleHealthClientError.offline
            }
            throw GoogleHealthClientError.requestFailed
        }
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleHealthClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 429 || (500...599).contains(httpResponse.statusCode) {
                throw GoogleHealthClientError.retryable(retryAfter: httpResponse.statusCode == 429 ? max(30, HTTPRetryDelay.parse(httpResponse.value(forHTTPHeaderField: "Retry-After")) ?? 30) : HTTPRetryDelay.parse(httpResponse.value(forHTTPHeaderField: "Retry-After")))
            }
            throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GoogleHealthClientError.invalidResponse
        }
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> GoogleHealthClientError {
        let payload = try? JSONDecoder().decode(GoogleAPIErrorEnvelope.self, from: data)
        let reasons = Set(payload?.error.details?.filter {
            $0.type == "type.googleapis.com/google.rpc.ErrorInfo" && $0.domain == "health.googleapis.com"
        }.compactMap(\.reason) ?? [])
        if reasons.contains("ACCOUNT_NOT_LINKED") { return .accountNotLinked }
        if reasons.contains("MISSING_OAUTH_SCOPE") { return .missingOAuthScope }
        if statusCode == 401 { return .authenticationRequired }
        return .requestFailed
    }
}

enum GoogleHealthMapper {
    static func steps(
        from response: DailyRollupResponse,
        expectedDay: LocalDay
    ) throws -> MetricState<DailyMetricValue> {
        let points = response.rollupDataPoints.filter { $0.civilStartTime.date.localDay == expectedDay }
        guard points.count <= 1 else { throw GoogleHealthClientError.invalidResponse }
        guard let point = points.first else { return .noData }
        guard point.civilStartTime.isMidnight, point.civilEndTime.isMidnight,
              let start = expectedDay.validatedDate(),
              let end = point.civilEndTime.date.localDay.validatedDate(),
              end.timeIntervalSince(start) == 86_400 else {
            throw GoogleHealthClientError.invalidResponse
        }
        // An empty rollup bucket has no value; an explicitly supplied zero remains data.
        guard let steps = point.steps else { return .noData }
        guard let count = Int(steps.countSum), count >= 0 else {
            throw GoogleHealthClientError.invalidResponse
        }
        return .value(DailyMetricValue(value: count, sourceDay: expectedDay))
    }

    static func sleep(
        from response: DataPointsResponse,
        at evaluationDate: Date,
        calendar: Calendar
    ) throws -> MetricState<SleepSession> {
        var candidates: [(end: Date, sleep: SleepDTO)] = []
        for point in response.dataPoints {
            guard let sleep = point.sleep, sleep.metadata?.mainSleep == true,
                  sleep.metadata?.nap != true else { continue }
            let end = try timestamp(sleep.interval.endTime)
            let age = evaluationDate.timeIntervalSince(end)
            if (0...(36 * 60 * 60)).contains(age) { candidates.append((end, sleep)) }
        }
        guard let latest = candidates.max(by: { $0.end < $1.end }) else { return .noData }
        let sleep = latest.sleep
        // A still-processing session may not yet have a headline. Never use an older session instead.
        guard let text = sleep.summary?.minutesAsleep else { return .noData }
        guard let minutes = Int(text), minutes >= 0, minutes <= Int.max / 60 else {
            throw GoogleHealthClientError.invalidResponse
        }
        let start = try zonedInstant(civil: sleep.interval.civilStartTime,
                                    timestamp: sleep.interval.startTime, offset: sleep.interval.startUtcOffset)
        let end = try zonedInstant(civil: sleep.interval.civilEndTime,
                                  timestamp: sleep.interval.endTime, offset: sleep.interval.endUtcOffset)
        guard try timestamp(sleep.interval.startTime) <= latest.end else {
            throw GoogleHealthClientError.invalidResponse
        }
        return .value(SleepSession(minutesAsleep: minutes, start: start, end: end,
                                   stages: try sleepStageState(sleep)))
    }

    static func restingHeartRate(
        from response: DataPointsResponse,
        at evaluationDate: Date,
        calendar: Calendar
    ) throws -> MetricState<DailyMetricValue> {
        let values = try response.dataPoints.compactMap { point -> DailyMetricValue? in
            guard let value = point.dailyRestingHeartRate else { return nil }
            guard let bpm = Int(value.beatsPerMinute), bpm >= 0,
                  value.date.localDay.validatedDate() != nil else {
                throw GoogleHealthClientError.invalidResponse
            }
            return DailyMetricValue(value: bpm, sourceDay: value.date.localDay)
        }
        return recent(values, at: evaluationDate, calendar: calendar)
    }

    static func hrv(
        from response: DataPointsResponse,
        at evaluationDate: Date,
        calendar: Calendar
    ) throws -> MetricState<DailyMetricValue> {
        let values = try response.dataPoints.compactMap { point -> DailyMetricValue? in
            guard let value = point.dailyHeartRateVariability else { return nil }
            guard value.date.localDay.validatedDate() != nil else { throw GoogleHealthClientError.invalidResponse }
            guard let average = value.averageHeartRateVariabilityMilliseconds else { return nil }
            guard average.isFinite, average >= 0, let integer = Int(exactly: average.rounded()) else {
                throw GoogleHealthClientError.invalidResponse
            }
            return DailyMetricValue(
                value: integer,
                sourceDay: value.date.localDay
            )
        }
        return recent(values, at: evaluationDate, calendar: calendar)
    }

    private static func recent(
        _ values: [DailyMetricValue],
        at evaluationDate: Date,
        calendar: Calendar
    ) -> MetricState<DailyMetricValue> {
        let evaluationDay = LocalDay(date: evaluationDate, calendar: calendar)
        let valid = values.filter { value in
            guard let sourceDate = value.sourceDay.date(in: calendar),
                  let evaluationDayDate = evaluationDay.date(in: calendar),
                  let age = calendar.dateComponents(
                    [.day],
                    from: sourceDate,
                    to: evaluationDayDate
                  ).day else {
                return false
            }
            return (0...3).contains(age)
        }
        guard let latest = valid.max(by: { lhs, rhs in
            (lhs.sourceDay.date(in: calendar) ?? .distantPast)
                < (rhs.sourceDay.date(in: calendar) ?? .distantPast)
        }) else {
            return .noData
        }
        return .value(latest)
    }

    private static func sleepStageState(_ sleep: SleepDTO) throws -> SleepStageState {
        if let status = sleep.metadata?.stagesStatus,
           status != "SUCCEEDED", status != "STAGES_STATE_UNSPECIFIED" { return .unavailable }
        if sleep.metadata?.processed == false { return .processing }
        guard sleep.type == "STAGES",
              sleep.metadata?.stagesStatus == "SUCCEEDED" else {
            return .unavailable
        }

        var durations: [String: Int] = [:]
        for stage in sleep.summary?.stagesSummary ?? [] {
            guard let minutes = Int(stage.minutes), minutes >= 0, minutes <= Int.max / 4,
                  durations[stage.type] == nil else {
                throw GoogleHealthClientError.invalidResponse
            }
            durations[stage.type] = minutes
        }
        guard ["AWAKE", "LIGHT", "REM", "DEEP"].contains(where: { durations[$0] != nil }) else { return .unavailable }
        return .available(SleepStages(
            awakeMinutes: durations["AWAKE"],
            lightMinutes: durations["LIGHT"],
            remMinutes: durations["REM"],
            deepMinutes: durations["DEEP"]
        ))
    }

    private static func zonedInstant(
        civil: CivilDateTime?,
        timestamp: String,
        offset: String
    ) throws -> ZonedInstant {
        guard let offsetSeconds = durationSeconds(offset), (-64_800...64_800).contains(offsetSeconds) else {
            throw GoogleHealthClientError.invalidResponse
        }

        let instant: Date
        if let civil {
            guard let timeZone = TimeZone(secondsFromGMT: offsetSeconds) else {
                throw GoogleHealthClientError.invalidResponse
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            var components = DateComponents()
            components.year = civil.date.year
            components.month = civil.date.month
            components.day = civil.date.day
            components.hour = civil.time?.hours ?? 0
            components.minute = civil.time?.minutes ?? 0
            components.second = civil.time?.seconds ?? 0
            guard civil.date.localDay.validatedDate() != nil,
                  (0...23).contains(components.hour ?? -1),
                  (0...59).contains(components.minute ?? -1),
                  (0...59).contains(components.second ?? -1),
                  let parsed = calendar.date(from: components) else {
                throw GoogleHealthClientError.invalidResponse
            }
            instant = parsed
        } else {
            instant = try self.timestamp(timestamp)
        }
        return ZonedInstant(instant: instant, utcOffsetSeconds: offsetSeconds)
    }

    private static func timestamp(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            throw GoogleHealthClientError.invalidResponse
        }
        return date
    }

    private static func durationSeconds(_ value: String) -> Int? {
        guard value.hasSuffix("s"),
              let seconds = Double(value.dropLast()),
              seconds.isFinite else {
            return nil
        }
        return Int(exactly: seconds)
    }
}

struct IdentityResponse: Decodable {
    let healthUserId: String
}

struct GoogleAPIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let details: [Detail]?
    }

    struct Detail: Decodable {
        let reason: String?
        let type: String?
        let domain: String?
        enum CodingKeys: String, CodingKey { case reason, domain; case type = "@type" }
    }

    let error: APIError
}

struct DataPointsResponse: Decodable {
    let dataPoints: [GoogleHealthDataPoint]
    let nextPageToken: String?

    enum CodingKeys: String, CodingKey { case dataPoints, nextPageToken }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dataPoints = try values.decodeIfPresent([GoogleHealthDataPoint].self, forKey: .dataPoints) ?? []
        nextPageToken = try values.decodeIfPresent(String.self, forKey: .nextPageToken)
    }

    init(dataPoints: [GoogleHealthDataPoint], nextPageToken: String? = nil) {
        self.dataPoints = dataPoints
        self.nextPageToken = nextPageToken
    }
}

struct GoogleHealthDataPoint: Decodable {
    let sleep: SleepDTO?
    let dailyRestingHeartRate: DailyRestingHeartRateDTO?
    let dailyHeartRateVariability: DailyHeartRateVariabilityDTO?
}

struct SleepDTO: Decodable {
    struct Interval: Decodable {
        let startTime: String
        let startUtcOffset: String
        let endTime: String
        let endUtcOffset: String
        let civilStartTime: CivilDateTime?
        let civilEndTime: CivilDateTime?
    }

    struct Metadata: Decodable {
        let stagesStatus: String?
        let processed: Bool?
        let nap: Bool?
        let mainSleep: Bool?
    }

    struct Summary: Decodable {
        let stagesSummary: [StageSummary]?
        let minutesAsleep: String?
    }

    struct StageSummary: Decodable {
        let type: String
        let minutes: String
    }

    let interval: Interval
    let type: String?
    let metadata: Metadata?
    let summary: Summary?
}

struct DailyRestingHeartRateDTO: Decodable {
    let date: GoogleDate
    let beatsPerMinute: String
}

struct DailyHeartRateVariabilityDTO: Decodable {
    let date: GoogleDate
    let averageHeartRateVariabilityMilliseconds: Double?
}

struct DailyRollupResponse: Decodable {
    struct Point: Decodable {
        struct Steps: Decodable {
            let countSum: String
        }

        let civilStartTime: CivilDateTime
        let civilEndTime: CivilDateTime
        let steps: Steps?
    }

    let rollupDataPoints: [Point]

    enum CodingKeys: String, CodingKey { case rollupDataPoints }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rollupDataPoints = try values.decodeIfPresent([Point].self, forKey: .rollupDataPoints) ?? []
    }
}

struct DailyRollupRequest: Encodable {
    let range: CivilRange
    let windowSizeDays: Int
    let dataSourceFamily: String
}

struct CivilRange: Codable {
    let start: CivilDateTime
    let end: CivilDateTime
}

struct CivilDateTime: Codable {
    let date: GoogleDate
    let time: CivilTime?

    var isMidnight: Bool {
        (time?.hours ?? 0) == 0 && (time?.minutes ?? 0) == 0 && (time?.seconds ?? 0) == 0 && (time?.nanos ?? 0) == 0
    }

    init(date: LocalDay, time: CivilTime?) {
        self.date = GoogleDate(year: date.year, month: date.month, day: date.day)
        self.time = time
    }
}

struct CivilTime: Codable {
    let hours: Int?
    let minutes: Int?
    let seconds: Int?
    let nanos: Int?

    init(hours: Int? = nil, minutes: Int? = nil, seconds: Int? = nil, nanos: Int? = nil) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.nanos = nanos
    }
}

struct GoogleDate: Codable {
    let year: Int
    let month: Int
    let day: Int

    var localDay: LocalDay { LocalDay(year: year, month: month, day: day) }
}

private extension LocalDay {
    var apiDate: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

private extension LocalDay {
    func validatedDate() -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = date(in: calendar), LocalDay(date: date, calendar: calendar) == self else { return nil }
        return date
    }
}
