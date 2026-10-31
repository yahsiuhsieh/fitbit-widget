import Foundation
import XCTest

final class Build3OAuthTests: XCTestCase {
    func testPKCEUsesS256AndSecureVerifierShape() throws {
        XCTAssertEqual(
            PKCEPair.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )

        let pair = try PKCEPair.generate()
        XCTAssertTrue((43...128).contains(pair.verifier.count))
        XCTAssertTrue(pair.verifier.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        })
        XCTAssertFalse(pair.challenge.contains("="))
    }

    func testCallbackValidationAcceptsCodeAndCancellation() throws {
        let codeURL = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/oauth2/callback?code=abc&state=expected"))
        XCTAssertEqual(
            try OAuthCallbackValidator.validate(
                codeURL,
                expectedPath: "/oauth2/callback",
                expectedState: "expected",
                expectedPort: 49_152
            ),
            .code("abc")
        )

        let cancelURL = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/oauth2/callback?error=access_denied&state=expected"))
        XCTAssertEqual(
            try OAuthCallbackValidator.validate(
                cancelURL,
                expectedPath: "/oauth2/callback",
                expectedState: "expected",
                expectedPort: 49_152
            ),
            .cancelled
        )
    }

    func testCallbackRejectsWrongStatePathAndMalformedResponse() throws {
        let wrongState = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/oauth2/callback?code=abc&state=wrong"))
        XCTAssertThrowsError(try OAuthCallbackValidator.validate(
            wrongState,
            expectedPath: "/oauth2/callback",
            expectedState: "expected",
            expectedPort: 49_152
        )) { XCTAssertEqual($0 as? GoogleHealthOAuthError, .stateMismatch) }

        for value in [
            "http://127.0.0.1:49152/wrong?code=abc&state=expected",
            "http://localhost:49152/oauth2/callback?code=abc&state=expected",
            "http://127.0.0.1:49152/oauth2/callback?state=expected"
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertThrowsError(try OAuthCallbackValidator.validate(
                url,
                expectedPath: "/oauth2/callback",
                expectedState: "expected",
                expectedPort: 49_152
            ))
        }
    }

    func testTokenResponseAndPartialScopeDerivation() throws {
        let response = try JSONDecoder().decode(OAuthTokenResponse.self, from: Data(#"""
        {
          "access_token":"",
          "expires_in":3599,
          "refresh_token":"",
          "refresh_token_expires_in":604800,
          "scope":"https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly https://www.googleapis.com/auth/googlehealth.sleep.readonly",
          "token_type":"Bearer"
        }
        """#.utf8))

        XCTAssertEqual(response.accessToken, "")
        XCTAssertEqual(response.refreshToken, "")
        let scopes = Set(try XCTUnwrap(response.scope).split(separator: " ").map(String.init))
        XCTAssertEqual(
            GoogleHealthScope.permissions(from: scopes).grantedMetrics,
            [.steps, .sleep]
        )
    }
}

final class Build3GoogleHealthMappingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    func testStepsMapsZeroAndMissingWithoutConflatingThem() throws {
        let zero = try decodeDailyRollup(#"""
        {
          "rollupDataPoints":[{
            "civilStartTime":{"date":{"year":2026,"month":10,"day":30},"time":{}},
            "civilEndTime":{"date":{"year":2026,"month":10,"day":31},"time":{}},
            "steps":{"countSum":"0"}
          }]
        }
        """#)
        let day = LocalDay(year: 2026, month: 10, day: 30)
        XCTAssertEqual(
            try GoogleHealthMapper.steps(from: zero, expectedDay: day),
            .value(DailyMetricValue(value: 0, sourceDay: day))
        )

        let missing = try decodeDailyRollup(#"{"rollupDataPoints":[]}"#)
        XCTAssertEqual(
            try GoogleHealthMapper.steps(from: missing, expectedDay: day),
            .noData
        )
    }

    func testSleepChoosesLatestMainSleepPreservesCivilTimesAndMissingStage() throws {
        let response = try decodeDataPoints(#"""
        {
          "dataPoints":[
            {
              "sleep":{
                "interval":{
                  "startTime":"2026-10-29T04:00:00Z","startUtcOffset":"-18000s",
                  "endTime":"2026-10-29T12:00:00Z","endUtcOffset":"-18000s",
                  "civilStartTime":{"date":{"year":2026,"month":10,"day":28},"time":{"hours":23}},
                  "civilEndTime":{"date":{"year":2026,"month":10,"day":29},"time":{"hours":7}}
                },
                "type":"STAGES",
                "metadata":{"stagesStatus":"SUCCEEDED","processed":true,"nap":false,"mainSleep":true},
                "summary":{"minutesAsleep":"420","stagesSummary":[{"type":"LIGHT","minutes":"250"}]}
              }
            },
            {
              "sleep":{
                "interval":{
                  "startTime":"2026-10-30T04:30:00Z","startUtcOffset":"-18000s",
                  "endTime":"2026-10-30T12:30:00Z","endUtcOffset":"-18000s",
                  "civilStartTime":{"date":{"year":2026,"month":10,"day":29},"time":{"hours":23,"minutes":30}},
                  "civilEndTime":{"date":{"year":2026,"month":10,"day":30},"time":{"hours":7,"minutes":30}}
                },
                "type":"STAGES",
                "metadata":{"stagesStatus":"SUCCEEDED","processed":true,"nap":false,"mainSleep":true},
                "summary":{"minutesAsleep":"455","stagesSummary":[
                  {"type":"AWAKE","minutes":"25"},{"type":"LIGHT","minutes":"260"},
                  {"type":"REM","minutes":"105"}
                ]}
              }
            },
            {
              "sleep":{
                "interval":{"startTime":"2026-10-30T18:00:00Z","startUtcOffset":"-18000s","endTime":"2026-10-30T19:00:00Z","endUtcOffset":"-18000s"},
                "type":"CLASSIC",
                "metadata":{"processed":true,"nap":true,"mainSleep":false},
                "summary":{"minutesAsleep":"55"}
              }
            }
          ]
        }
        """#)
        let evaluation = try date(2026, 10, 30, 12)
        let mapped = try GoogleHealthMapper.sleep(from: response, at: evaluation, calendar: calendar)
        guard case let .value(session) = mapped else { return XCTFail("Expected sleep") }

        XCTAssertEqual(session.minutesAsleep, 455)
        XCTAssertEqual(session.end.utcOffsetSeconds, -18_000)
        var fixedCalendar = Calendar(identifier: .gregorian)
        fixedCalendar.timeZone = TimeZone(secondsFromGMT: -18_000)!
        let endComponents = fixedCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: session.end.instant)
        XCTAssertEqual(endComponents, DateComponents(year: 2026, month: 10, day: 30, hour: 7, minute: 30))

        guard case let .available(stages) = session.stages else { return XCTFail("Expected stages") }
        XCTAssertEqual(stages.awakeMinutes, 25)
        XCTAssertEqual(stages.lightMinutes, 260)
        XCTAssertEqual(stages.remMinutes, 105)
        XCTAssertNil(stages.deepMinutes)
    }

    func testSleepProcessingAndTimestampOffsetFallback() throws {
        let response = try decodeDataPoints(#"""
        {
          "dataPoints":[{
            "sleep":{
              "interval":{"startTime":"2026-10-30T04:00:00Z","startUtcOffset":"-18000s","endTime":"2026-10-30T12:00:00Z","endUtcOffset":"-18000s"},
              "type":"STAGES",
              "metadata":{"processed":false,"nap":false,"mainSleep":true},
              "summary":{"minutesAsleep":"430"}
            }
          }]
        }
        """#)
        let mapped = try GoogleHealthMapper.sleep(
            from: response,
            at: try date(2026, 10, 30, 12),
            calendar: calendar
        )
        guard case let .value(session) = mapped else { return XCTFail("Expected sleep") }
        XCTAssertEqual(session.stages, .processing)
        XCTAssertEqual(session.start.utcOffsetSeconds, -18_000)
    }

    func testRestingHeartRateAndHRVChooseLatestValidSourceDate() throws {
        let response = try decodeDataPoints(#"""
        {
          "dataPoints":[
            {"dailyRestingHeartRate":{"date":{"year":2026,"month":10,"day":26},"beatsPerMinute":"58"}},
            {"dailyRestingHeartRate":{"date":{"year":2026,"month":10,"day":29},"beatsPerMinute":"61"}},
            {"dailyHeartRateVariability":{"date":{"year":2026,"month":10,"day":28},"averageHeartRateVariabilityMilliseconds":47.6}}
          ]
        }
        """#)
        let evaluation = try date(2026, 10, 30, 12)

        XCTAssertEqual(
            try GoogleHealthMapper.restingHeartRate(from: response, at: evaluation, calendar: calendar),
            .value(DailyMetricValue(value: 61, sourceDay: LocalDay(year: 2026, month: 10, day: 29)))
        )
        XCTAssertEqual(
            try GoogleHealthMapper.hrv(from: response, at: evaluation, calendar: calendar),
            .value(DailyMetricValue(value: 48, sourceDay: LocalDay(year: 2026, month: 10, day: 28)))
        )
    }

    func testCorruptProviderNumberFailsInsteadOfBecomingMissing() throws {
        let response = try decodeDailyRollup(#"""
        {
          "rollupDataPoints":[{
            "civilStartTime":{"date":{"year":2026,"month":10,"day":30},"time":{}},
            "civilEndTime":{"date":{"year":2026,"month":10,"day":31},"time":{}},
            "steps":{"countSum":"not-a-number"}
          }]
        }
        """#)
        XCTAssertThrowsError(try GoogleHealthMapper.steps(
            from: response,
            expectedDay: LocalDay(year: 2026, month: 10, day: 30)
        )) { XCTAssertEqual($0 as? GoogleHealthClientError, .invalidResponse) }
    }

    private func decodeDataPoints(_ json: String) throws -> DataPointsResponse {
        try JSONDecoder().decode(DataPointsResponse.self, from: Data(json.utf8))
    }

    private func decodeDailyRollup(_ json: String) throws -> DailyRollupResponse {
        try JSONDecoder().decode(DailyRollupResponse.self, from: Data(json.utf8))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        )))
    }
}

final class Build3HTTPTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testIdentitySuccessAndAccountNotLinkedMapping() async throws {
        let session = makeSession()
        let client = GoogleHealthClient(
            baseURL: URL(string: "https://health.googleapis.com/v4/")!,
            session: session
        )

        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v4/users/me/identity")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ")
            return Self.response(request, status: 200, json: #"{"name":"users/me/identity","legacyUserId":"ABC123","healthUserId":"health-1"}"#)
        }
        let identity = try await client.identity(accessToken: "")
        XCTAssertEqual(identity, GoogleHealthIdentity(healthUserID: "health-1"))

        StubURLProtocol.handler = { request in
            Self.response(request, status: 400, json: #"""
            {
              "error":{"code":400,"message":"not linked","status":"FAILED_PRECONDITION","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","domain":"health.googleapis.com","reason":"ACCOUNT_NOT_LINKED"}]}
            }
            """#)
        }
        do {
            _ = try await client.identity(accessToken: "")
            XCTFail("Expected account-not-linked error")
        } catch {
            XCTAssertEqual(error as? GoogleHealthClientError, .accountNotLinked)
        }
    }

    func testStepsHTTPUsesDailyRollupAndGoogleSources() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v4/users/me/dataTypes/steps/dataPoints:dailyRollUp")
            let body = try Self.bodyData(from: request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["dataSourceFamily"] as? String, GoogleHealthClient.googleSources)
            XCTAssertEqual(object["windowSizeDays"] as? Int, 1)
            return Self.response(request, status: 200, json: #"""
            {
              "rollupDataPoints":[{
                "civilStartTime":{"date":{"year":2026,"month":10,"day":30},"time":{}},
                "civilEndTime":{"date":{"year":2026,"month":10,"day":31},"time":{}},
                "steps":{"countSum":"1234"}
              }]
            }
            """#)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let client = GoogleHealthClient(
            baseURL: URL(string: "https://health.googleapis.com/v4/")!,
            session: makeSession()
        )
        let steps = try await client.steps(
            for: LocalDay(year: 2026, month: 10, day: 30),
            calendar: calendar,
            accessToken: ""
        )
        XCTAssertEqual(
            steps,
            .value(DailyMetricValue(
                value: 1_234,
                sourceDay: LocalDay(year: 2026, month: 10, day: 30)
            ))
        )
    }

    fileprivate func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    fileprivate static func response(
        _ request: URLRequest,
        status: Int,
        json: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(json.utf8)
        )
    }

    fileprivate static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw GoogleHealthClientError.requestFailed }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

fileprivate final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: GoogleHealthClientError.requestFailed)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension Build3OAuthTests {
    func testPKCELimitsAndRandomness() throws {
        XCTAssertNotEqual(try PKCEPair.generate(), try PKCEPair.generate())
        XCTAssertEqual(try PKCEPair.generate(randomByteCount: 96).verifier.count, 128)
        XCTAssertThrowsError(try PKCEPair.generate(randomByteCount: 31))
        XCTAssertThrowsError(try PKCEPair.generate(randomByteCount: 97))
    }

    func testAmbiguousCallbacksAreRejected() throws {
        for suffix in [
            "?code=x&state=expected&state=wrong", "?code=x&code=y&state=expected",
            "?code=x&error=access_denied&state=expected", "?code=x&state=expected#fragment",
            "?code=&state=expected", "?code=x&state=expected&scope"
        ] {
            XCTAssertThrowsError(try OAuthCallbackValidator.validate(
                XCTUnwrap(URL(string: "http://127.0.0.1:49152/oauth2/callback" + suffix)),
                expectedPath: "/oauth2/callback", expectedState: "expected", expectedPort: 49152))
        }
        XCTAssertThrowsError(try OAuthCallbackValidator.validate(
            XCTUnwrap(URL(string: "http://127.0.0.1:49153/oauth2/callback?code=x&state=expected")),
            expectedPath: "/oauth2/callback", expectedState: "expected", expectedPort: 49152))
    }

    func testAuthorizationURLHasOnlyReadScopesAndNoSecret() throws {
        let authorizer = GoogleHealthAuthorizer(configuration: .init(clientID: ""))
        let url = try authorizer.makeAuthorizationURL(
            redirectURI: XCTUnwrap(URL(string: "http://127.0.0.1:49152/oauth2/callback")),
            state: "expected", challenge: "challenge")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let parameters = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(parameters["code_challenge_method"], "S256")
        XCTAssertEqual(parameters["state"], "expected")
        XCTAssertEqual(parameters["response_type"], "code")
        XCTAssertEqual(parameters["access_type"], "offline")
        XCTAssertEqual(Set(parameters["scope"]!.split(separator: " ").map(String.init)), Set(GoogleHealthScope.requested))
        XCTAssertNil(parameters["client_secret"])
        XCTAssertFalse(url.absoluteString.contains("fitbitwidget:"))
        XCTAssertEqual(GoogleHealthScope.permissions(from: []), .none)
        XCTAssertEqual(GoogleHealthScope.permissions(from: Set(GoogleHealthScope.requested)), .all)
        XCTAssertEqual(GoogleHealthScope.permissions(from: [GoogleHealthScope.healthMetrics]).grantedMetrics, [.restingHeartRate, .hrv])
    }

    func testMissingConfigurationFailsClearly() {
        XCTAssertThrowsError(try GoogleHealthConfiguration.load(bundle: Bundle(for: Self.self))) {
            XCTAssertEqual($0 as? GoogleHealthOAuthError, .missingConfiguration)
        }
    }

    func testListenerCancellationBeforeStartAndTimeout() async throws {
        let cancelled = OAuthLoopbackListener(callbackPath: "/oauth2/callback", expectedState: "expected")
        cancelled.cancel()
        do { _ = try await cancelled.start(); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await cancelled.waitForCallback(); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }

        let listener = OAuthLoopbackListener(callbackPath: "/oauth2/callback", expectedState: "expected", timeout: 0.1)
        defer { listener.cancel() }
        do {
            _ = try await listener.start()
            _ = try await listener.waitForCallback()
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? GoogleHealthOAuthError, .timedOut)
        }
    }

    func testLoopbackRejectsWrongStateThenAcceptsCancellationCallback() async throws {
        let listener = OAuthLoopbackListener(callbackPath: "/oauth2/callback", expectedState: "expected", timeout: 3)
        defer { listener.cancel() }
        let redirect = try await listener.start()
        XCTAssertEqual(redirect.host, "127.0.0.1")
        XCTAssertGreaterThan(try XCTUnwrap(redirect.port), 0)
        let session = GoogleHealthHTTP.makeSession()
        defer { session.invalidateAndCancel() }
        let wrong = URL(string: redirect.absoluteString + "?state=wrong&code=x")!
        let (_, response) = try await session.data(from: wrong)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        let denied = URL(string: redirect.absoluteString + "?state=expected&error=access_denied")!
        _ = try await session.data(from: denied)
        let callback = try await listener.waitForCallback()
        XCTAssertEqual(callback, .cancelled)
    }
}

extension Build3GoogleHealthMappingTests {
    func testOmittedRepeatedFieldsAreSuccessfulEmptyResponses() throws {
        let day = LocalDay(year: 2026, month: 10, day: 30)
        let rollup = try JSONDecoder().decode(DailyRollupResponse.self, from: Data("{}".utf8))
        XCTAssertEqual(try GoogleHealthMapper.steps(from: rollup, expectedDay: day), .noData)
        let points = try JSONDecoder().decode(DataPointsResponse.self, from: Data("{}".utf8))
        XCTAssertEqual(try GoogleHealthMapper.sleep(from: points, at: Date(), calendar: .current), .noData)
        let emptyBucket = try JSONDecoder().decode(DailyRollupResponse.self, from: Data(#"""
        {"rollupDataPoints":[{"civilStartTime":{"date":{"year":2026,"month":10,"day":30}},"civilEndTime":{"date":{"year":2026,"month":10,"day":31}}}]}
        """#.utf8))
        XCTAssertEqual(try GoogleHealthMapper.steps(from: emptyBucket, expectedDay: day), .noData)
        XCTAssertThrowsError(try JSONDecoder().decode(DataPointsResponse.self, from: Data(#"{"dataPoints":"invalid"}"#.utf8)))
    }

    func testClassicRejectedAndIncompleteStagesDoNotBecomeZero() throws {
        let base = #"""
        {"dataPoints":[{"sleep":{
          "interval":{"startTime":"2026-10-30T04:00:00Z","startUtcOffset":"-18000s","endTime":"2026-10-30T12:00:00Z","endUtcOffset":"-18000s"},
          "type":"CLASSIC","metadata":{"mainSleep":true,"processed":true},
          "summary":{"minutesAsleep":"400"}
        }}]}
        """#
        let evaluation = ISO8601DateFormatter().date(from: "2026-10-30T15:00:00Z")!
        for json in [base, base.replacingOccurrences(of: "\"CLASSIC\"", with: "\"STAGES\"")
            .replacingOccurrences(of: "\"processed\":true", with: "\"processed\":false,\"stagesStatus\":\"REJECTED_SERVER\"")] {
            let response = try JSONDecoder().decode(DataPointsResponse.self, from: Data(json.utf8))
            guard case let .value(sleep) = try GoogleHealthMapper.sleep(from: response, at: evaluation, calendar: .current) else {
                return XCTFail("Expected headline")
            }
            XCTAssertEqual(sleep.minutesAsleep, 400)
            XCTAssertEqual(sleep.stages, .unavailable)
            XCTAssertEqual(sleep.wakeDay, LocalDay(year: 2026, month: 10, day: 30))
        }
        let noHeadline = base.replacingOccurrences(of: "\"minutesAsleep\":\"400\"", with: "\"minutesAwake\":\"50\"")
        let response = try JSONDecoder().decode(DataPointsResponse.self, from: Data(noHeadline.utf8))
        XCTAssertEqual(try GoogleHealthMapper.sleep(from: response, at: evaluation, calendar: .current), .noData)
    }

    func testInvalidNumbersAndDatesFailWithoutTrapping() throws {
        for number in ["-1", "1e300"] {
            let json = "{\"dataPoints\":[{\"dailyHeartRateVariability\":{\"date\":{\"year\":2026,\"month\":10,\"day\":30},\"averageHeartRateVariabilityMilliseconds\":\(number)}}]}"
            let response = try JSONDecoder().decode(DataPointsResponse.self, from: Data(json.utf8))
            XCTAssertThrowsError(try GoogleHealthMapper.hrv(from: response, at: Date(), calendar: .current))
        }
        let invalidDate = try JSONDecoder().decode(DataPointsResponse.self, from: Data(#"{"dataPoints":[{"dailyRestingHeartRate":{"date":{"year":2026,"month":2,"day":31},"beatsPerMinute":"60"}}]}"#.utf8))
        XCTAssertThrowsError(try GoogleHealthMapper.restingHeartRate(from: invalidDate, at: Date(), calendar: .current))
    }
}

extension Build3HTTPTests {
    func testPaginationUsesEveryPageAndDetectsRepeatedTokens() async throws {
        let client = GoogleHealthClient(baseURL: URL(string: "https://health.googleapis.com/v4/")!, session: makeSession())
        let evaluation = ISO8601DateFormatter().date(from: "2026-10-30T15:00:00Z")!
        StubURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first(where: { $0.name == "dataSourceFamily" })?.value, GoogleHealthClient.googleSources)
            XCTAssertTrue(query.first(where: { $0.name == "filter" })!.value!.contains("daily_resting_heart_rate.date"))
            if query.contains(where: { $0.name == "pageToken" }) {
                return Self.response(request, status: 200, json: #"{"dataPoints":[{"dailyRestingHeartRate":{"date":{"year":2026,"month":10,"day":30},"beatsPerMinute":"62"}}]}"#)
            }
            return Self.response(request, status: 200, json: #"{"dataPoints":[],"nextPageToken":"page-2"}"#)
        }
        let result = try await client.restingHeartRate(at: evaluation, calendar: .current, accessToken: "")
        XCTAssertEqual(result, .value(DailyMetricValue(value: 62, sourceDay: LocalDay(year: 2026, month: 10, day: 30))))
        StubURLProtocol.handler = { Self.response($0, status: 200, json: #"{"nextPageToken":"same"}"#) }
        do { _ = try await client.hrv(at: evaluation, calendar: .current, accessToken: ""); XCTFail("Expected pagination failure") }
        catch { XCTAssertEqual(error as? GoogleHealthClientError, .invalidResponse) }
    }

    func testHTTPFailuresAndCorruptPayloadAreNotMissingData() async throws {
        let client = GoogleHealthClient(baseURL: URL(string: "https://health.googleapis.com/v4/")!, session: makeSession())
        for (status, json, expected) in [
            (401, "{}", GoogleHealthClientError.authenticationRequired),
            (403, #"{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","domain":"health.googleapis.com","reason":"MISSING_OAUTH_SCOPE"}]}}"#, .missingOAuthScope),
            (503, "{}", .retryable(retryAfter: nil)), (200, "not-json", .invalidResponse),
            (200, #"{"healthUserId":"invalid/id"}"#, .invalidResponse)
        ] {
            StubURLProtocol.handler = { Self.response($0, status: status, json: json) }
            do { _ = try await client.identity(accessToken: ""); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? GoogleHealthClientError, expected) }
        }
    }

    func testTokenExchangeIsFormEncodedWithoutSecretAndRejectsEmptyMaterial() async throws {
        // Empty credential fields exercise decoding/rejection without fabricating tokens.
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let body = String(data: try Self.bodyData(from: request), encoding: .utf8)!
            XCTAssertFalse(body.contains("client_secret"))
            XCTAssertTrue(body.contains("code=%2B%26%3D"))
            XCTAssertTrue(body.contains("code_verifier="))
            XCTAssertTrue(body.contains("grant_type=authorization_code"))
            return Self.response(request, status: 200, json: #"{"access_token":"","expires_in":3600,"token_type":"Bearer"}"#)
        }
        let authorizer = GoogleHealthAuthorizer(configuration: .init(clientID: ""), session: makeSession())
        do {
            _ = try await authorizer.exchangeAuthorizationCode("+&=", verifier: "", redirectURI: URL(string: "http://127.0.0.1:49152/oauth2/callback")!)
            XCTFail("Empty token material must fail")
        } catch { XCTAssertEqual(error as? GoogleHealthOAuthError, .tokenExchangeFailed) }
    }

    func testRefreshInvalidGrantRequiresReconnection() async throws {
        StubURLProtocol.handler = { request in
            let body = String(data: try Self.bodyData(from: request), encoding: .utf8)!
            XCTAssertTrue(body.contains("grant_type=refresh_token"))
            XCTAssertFalse(body.contains("client_secret"))
            return Self.response(request, status: 400, json: #"{"error":"invalid_grant"}"#)
        }
        let authorizer = GoogleHealthAuthorizer(configuration: .init(clientID: ""), session: makeSession())
        do { _ = try await authorizer.refresh(emptyCredentialMetadata()); XCTFail("Expected revoked grant") }
        catch { XCTAssertEqual(error as? GoogleHealthOAuthError, .refreshUnavailable) }
    }

    func testTokenRejectionDiagnosticsDoNotExposeFreeFormResponses() async throws {
        let authorizer = GoogleHealthAuthorizer(configuration: .init(clientID: ""), session: makeSession())
        let fixtures: [(String, GoogleHealthOAuthError)] = [
            (#"{"error":"invalid_request","error_description":"client_secret is missing."}"#, .clientSecretRequired),
            (#"{"error":"invalid_grant","error_description":"private details"}"#, .tokenRequestRejected(status: 400, reason: "invalid_grant")),
            (#"{"error":"private-response-value","error_description":"private details"}"#, .tokenRequestRejected(status: 400, reason: "unclassified"))
        ]
        for (json, expected) in fixtures {
            StubURLProtocol.handler = { Self.response($0, status: 400, json: json) }
            do {
                _ = try await authorizer.exchangeAuthorizationCode("", verifier: "", redirectURI: URL(string: "http://127.0.0.1:49152/oauth2/callback")!)
                XCTFail("Expected rejection")
            } catch { XCTAssertEqual(error as? GoogleHealthOAuthError, expected) }
        }
    }

    func testProductionHTTPDoesNotPersistResponsesOrCredentials() {
        let session = GoogleHealthHTTP.makeSession()
        defer { session.invalidateAndCancel() }
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCredentialStorage)
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertLessThanOrEqual(session.configuration.timeoutIntervalForResource, 60)
    }
}

// Credential fields are intentionally empty: these are in-memory metadata fixtures, never usable tokens.
private func emptyCredentialMetadata(scopes: Set<String> = Set(GoogleHealthScope.requested), user: String? = "health-1") -> OAuthTokenSet {
    OAuthTokenSet(accessToken: "", refreshToken: "", accessTokenExpiration: .distantFuture,
                  refreshTokenExpiration: nil, grantedScopes: scopes, healthUserID: user)
}

@MainActor
final class Build3WorkflowTests: XCTestCase {
    func testPartialConnectionRequiresIdentityBeforeTokensOrData() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.clear() }
        fixture.authorized = emptyCredentialMetadata(scopes: [GoogleHealthScope.sleep], user: nil)
        StubURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("identity") {
                XCTAssertNil(fixture.readCredentialBytes())
                return Build3HTTPTests.response(request, status: 200, json: #"{"healthUserId":"health-1"}"#)
            }
            XCTAssertTrue(request.url!.path.contains("/sleep/"))
            return Build3HTTPTests.response(request, status: 200, json: "{}")
        }
        let model = fixture.model()
        model.startConnection()
        try await finish(model)
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.state.selection.metrics, [.sleep])
        XCTAssertEqual(model.state.permissions.grantedMetrics, [.sleep])
        XCTAssertEqual(model.connectionTitle, "Connected · Partial Authorization")
        XCTAssertEqual(model.lastSuccessfulUpdate, fixture.date)
        XCTAssertEqual(try fixture.tokens.load()?.healthUserID, "health-1")
        guard case let .data(data) = model.state.content else { return XCTFail("Expected complete snapshot") }
        XCTAssertEqual(data.snapshot.sleep, .noData)
        XCTAssertEqual(data.snapshot.steps, .permissionRequired)
        XCTAssertEqual(fixture.store.load(), model.state)
        XCTAssertGreaterThan(fixture.reloads, 0)
        let saved = try String(contentsOf: fixture.store.fileURL, encoding: .utf8)
        XCTAssertFalse(saved.contains("accessToken"))
        XCTAssertFalse(saved.contains("health-1"))
    }

    func testFullAuthorizationCompletesAllFourRequestsBeforeSuccess() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.clear() }
        StubURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("identity") {
                return Build3HTTPTests.response(request, status: 200, json: #"{"healthUserId":"health-1"}"#)
            }
            return Build3HTTPTests.response(request, status: 200, json: "{}")
        }
        let model = fixture.model()
        model.startConnection()
        try await finish(model)
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.connectionTitle, "Connected")
        XCTAssertEqual(model.state.permissions, .all)
        XCTAssertEqual(model.state.selection, .all)
        guard case let .data(data) = model.state.content else { return XCTFail("Expected full commit") }
        XCTAssertEqual(data.snapshot.steps, .noData)
        XCTAssertEqual(data.snapshot.sleep, .noData)
        XCTAssertEqual(data.snapshot.restingHeartRate, .noData)
        XCTAssertEqual(data.snapshot.hrv, .noData)
        XCTAssertEqual(data.snapshot.lastSuccessfulUpdate, fixture.date)
    }

    func testIdentityFailureCannotEstablishConnectionOrStoreTokens() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.clear() }
        StubURLProtocol.handler = { Build3HTTPTests.response($0, status: 500, json: "{}") }
        let model = fixture.model()
        model.startConnection()
        try await finish(model)
        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(model.state, .initial)
        XCTAssertNil(try fixture.tokens.load())
        XCTAssertNotNil(model.message)
    }

    func testOAuthCancellationAndNoGrantedPermissionsRemainUnconnected() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.clear() }
        fixture.authorized = nil
        let model = fixture.model()
        model.startConnection()
        try await finish(model)
        XCTAssertEqual(model.state, .initial)
        XCTAssertNil(model.message)
        fixture.authorized = emptyCredentialMetadata(scopes: [], user: nil)
        model.startConnection()
        try await finish(model)
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(try fixture.tokens.load())
        XCTAssertNotNil(model.message)
    }

    func testUnlinkedAccountGetsGuidanceWithoutTokens() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.clear() }
        StubURLProtocol.handler = { Build3HTTPTests.response($0, status: 400, json: Self.scopeError("ACCOUNT_NOT_LINKED")) }
        let model = fixture.model()
        model.startConnection()
        try await finish(model)
        XCTAssertEqual(model.state.content, .accountNotLinked)
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(try fixture.tokens.load())
        XCTAssertTrue(model.connectionDetail.contains("same Google Account"))
        XCTAssertTrue(model.connectionDetail.contains("compatible phone"))
    }

    func testVerifiedIdentityWithFailedInitialDataIsDistinct() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.clear() }
        StubURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("identity") {
                return Build3HTTPTests.response(request, status: 200, json: #"{"healthUserId":"health-1"}"#)
            }
            return Build3HTTPTests.response(request, status: 503, json: "{}")
        }
        let model = fixture.model()
        model.startConnection()
        try await finish(model)
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.state.content, .initialSyncFailed)
        XCTAssertNil(model.lastSuccessfulUpdate)
        XCTAssertNotNil(try fixture.tokens.load())
    }

    func testFailedSecondMetricPreservesEntireSnapshotThenEmptySuccessCommits() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.clear() }
        let prior = try fixture.prepareConnected(selection: [.steps, .sleep])
        StubURLProtocol.handler = { request in
            Build3HTTPTests.response(request, status: request.url!.path.contains("/sleep/") ? 503 : 200, json: "{}")
        }
        let model = fixture.model()
        model.refresh()
        try await finish(model)
        guard case let .data(failed) = model.state.content else { return XCTFail("Expected prior snapshot") }
        XCTAssertEqual(failed.snapshot, prior)
        XCTAssertEqual(failed.lastSyncIssue, .updateFailed)
        XCTAssertEqual(model.lastSuccessfulUpdate, prior.lastSuccessfulUpdate)
        fixture.date = try XCTUnwrap(model.state.sync.nextAttempt).addingTimeInterval(1)
        StubURLProtocol.handler = { Build3HTTPTests.response($0, status: 200, json: "{}") }
        model.refresh()
        try await finish(model)
        guard case let .data(success) = fixture.store.load().content else { return XCTFail("Expected commit") }
        XCTAssertEqual(success.snapshot.steps, .noData)
        XCTAssertEqual(success.snapshot.sleep, .noData)
        XCTAssertEqual(success.snapshot.lastSuccessfulUpdate, fixture.date)
        XCTAssertNil(success.lastSyncIssue)
    }

    func testRevokedScopePreservesSnapshotDateAndWidgetPosition() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.clear() }
        let prior = try fixture.prepareConnected(selection: [.steps, .restingHeartRate, .hrv])
        StubURLProtocol.handler = { request in
            Build3HTTPTests.response(request, status: request.url!.path.contains("daily-resting") ? 403 : 200,
                                     json: request.url!.path.contains("daily-resting") ? Self.scopeError("MISSING_OAUTH_SCOPE") : "{}")
        }
        let model = fixture.model()
        model.refresh()
        try await finish(model)
        guard case let .data(data) = model.state.content else { return XCTFail("Expected prior data") }
        XCTAssertEqual(data.snapshot, prior)
        XCTAssertEqual(model.state.selection.metrics, [.steps, .restingHeartRate, .hrv])
        XCTAssertEqual(model.state.permissions.grantedMetrics, [.steps, .sleep])
        let displayed = data.snapshot.applyingPermissions(model.state.permissions)
        XCTAssertEqual(displayed.restingHeartRate, .permissionRequired)
        XCTAssertEqual(displayed.hrv, .permissionRequired)
        XCTAssertEqual(displayed.lastSuccessfulUpdate, prior.lastSuccessfulUpdate)
        XCTAssertEqual(displayed.steps, prior.steps)
        // The next manual fetch only requests metrics still authorized.
        StubURLProtocol.handler = { request in
            XCTAssertTrue(request.url!.path.contains("/steps/"))
            return Build3HTTPTests.response(request, status: 200, json: "{}")
        }
        model.refresh()
        try await finish(model)
        XCTAssertEqual(model.lastSuccessfulUpdate, fixture.date)
    }

    func testDifferentAccountNeverInheritsPriorSnapshotOnFailure() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.clear() }
        _ = try fixture.prepareConnected(selection: [.steps])
        StubURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("identity") {
                return Build3HTTPTests.response(request, status: 200, json: #"{"healthUserId":"health-2"}"#)
            }
            return Build3HTTPTests.response(request, status: 500, json: "{}")
        }
        let model = fixture.model()
        model.startConnection()
        try await finish(model)
        XCTAssertEqual(model.state.content, .initialSyncFailed)
        XCTAssertEqual(model.state.selection, .all)
        XCTAssertNil(model.lastSuccessfulUpdate)
        XCTAssertEqual(try fixture.tokens.load()?.healthUserID, "health-2")
    }

    func testSameAccountReauthorizationPreservesSelectionAndFailedSnapshot() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.clear() }
        let prior = try fixture.prepareConnected(selection: [.sleep])
        StubURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("identity") {
                return Build3HTTPTests.response(request, status: 200, json: #"{"healthUserId":"health-1"}"#)
            }
            return Build3HTTPTests.response(request, status: 500, json: "{}")
        }
        let model = fixture.model()
        model.startConnection()
        try await finish(model)
        XCTAssertEqual(model.state.selection.metrics, [.sleep])
        guard case let .data(data) = model.state.content else { return XCTFail("Expected preserved snapshot") }
        XCTAssertEqual(data.snapshot, prior)
    }

    func testResetClearsInjectedTokenBoundaryAndSharedState() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.clear() }
        _ = try fixture.prepareConnected(selection: [.steps])
        let model = fixture.model()
        model.resetLocalData()
        XCTAssertNil(try fixture.tokens.load())
        XCTAssertEqual(fixture.store.load(), .initial)
        XCTAssertEqual(model.state, .initial)
        XCTAssertNil(model.message)
        XCTAssertGreaterThan(fixture.reloads, 0)
    }

    func testResetStillClearsSnapshotWhenTokenDeletionFails() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.clear() }
        _ = try fixture.prepareConnected(selection: [.steps])
        fixture.failDelete = true
        let model = fixture.model()
        model.resetLocalData()
        XCTAssertEqual(fixture.store.load(), .initial)
        XCTAssertNotNil(model.message)
    }

    func testCancelledAuthorizationCannotWriteAfterReset() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.clear() }
        var continuation: CheckedContinuation<OAuthTokenSet?, Never>?
        let model = fixture.model(authorize: { _ in
            await withCheckedContinuation { continuation = $0 }
        })
        model.startConnection()
        while continuation == nil { await Task.yield() }
        model.resetLocalData()
        continuation?.resume(returning: emptyCredentialMetadata())
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.state, .initial)
        XCTAssertNil(try fixture.tokens.load())
        XCTAssertEqual(model.activity, .idle)
    }

    func testSampleStateNeverClaimsVerifiedConnectionOrSuccessfulRealUpdate() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.clear() }
        try fixture.store.save(Build2MockData.state())
        let model = fixture.model()
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.lastSuccessfulUpdate)
        XCTAssertEqual(model.connectionTitle, "Development Preview")
    }

    private func finish(_ model: CompanionAppModel) async throws {
        let deadline = Date().addingTimeInterval(12)
        while model.activity != .idle && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.activity, .idle, "Operation did not finish")
    }

    nonisolated private static func scopeError(_ reason: String) -> String {
        "{\"error\":{\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"domain\":\"health.googleapis.com\",\"reason\":\"\(reason)\"}]}}"
    }
}

@MainActor
private final class WorkflowFixture {
    let directory: URL
    let store: SharedWidgetStore
    var date = ISO8601DateFormatter().date(from: "2026-10-30T18:00:00Z")!
    private let memory = CredentialMemory()
    var failDelete = false
    var authorized: OAuthTokenSet? = emptyCredentialMetadata(user: nil)
    var reloads = 0

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SharedWidgetStore(containerURL: directory)
    }

    // URLProtocol runs outside MainActor. Only this locked in-memory boundary is shared with it.
    nonisolated func readCredentialBytes() -> Data? { memory.read() }

    var tokens: OAuthTokenStore {
        OAuthTokenStore(read: { self.memory.read() }, write: { self.memory.write($0) }, delete: {
            if self.failDelete { throw GoogleHealthClientError.requestFailed }
            self.memory.write(nil)
        })
    }

    func model(authorize: (@MainActor (GoogleHealthAuthorizer) async throws -> OAuthTokenSet?)? = nil) -> CompanionAppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return CompanionAppModel(sharedStore: store, tokenStore: { self.tokens },
                                 configuration: { GoogleHealthConfiguration(clientID: "") },
                                 session: URLSession(configuration: configuration),
                                 authorize: authorize ?? { _ in self.authorized },
                                 reloadWidget: { self.reloads += 1 }, now: { self.date })
    }

    func prepareConnected(selection: [MetricKind]) throws -> HealthSnapshot {
        let sample = Build2MockData.state(at: date.addingTimeInterval(-3600))
        try tokens.save(emptyCredentialMetadata())
        try store.save(SharedWidgetState(selection: MetricSelection(selection)!, content: sample.content,
                                        permissions: .all, hasVerifiedIdentity: true))
        guard case let .data(data) = sample.content else { fatalError("Fixture setup") }
        return data.snapshot
    }

    func clear() {
        StubURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class CredentialMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func read() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func write(_ value: Data?) { lock.lock(); defer { lock.unlock() }; data = value }
}

extension Build3OAuthTests {
    func testDesktopConfigurationRequiresMatchingLocalCredentials() throws {
        for secret in [nil, "", "  ", "$(GOOGLE_HEALTH_OAUTH_CLIENT_SECRET)"] as [String?] {
            XCTAssertThrowsError(try GoogleHealthConfiguration.load(clientID: "fixture-client", clientSecret: secret)) {
                XCTAssertEqual($0 as? GoogleHealthOAuthError, .missingClientSecret)
            }
        }
        let configuration = try GoogleHealthConfiguration.load(clientID: " fixture-client ", clientSecret: " fixture-value ")
        XCTAssertEqual(configuration.clientID, "fixture-client")
        XCTAssertEqual(configuration.clientSecret, "fixture-value")
        let authorizer = GoogleHealthAuthorizer(configuration: configuration)
        let url = try authorizer.makeAuthorizationURL(redirectURI: URL(string: "http://127.0.0.1:49152/oauth2/callback")!,
                                                       state: "state", challenge: "challenge")
        XCTAssertFalse(url.absoluteString.contains("client_secret"))
        XCTAssertFalse(url.absoluteString.contains("fixture-value"))
    }
}

extension Build3HTTPTests {
    func testDesktopClientSecretIsEncodedInBothTokenPOSTBodies() async throws {
        // A synthetic application-config value, never an OAuth token or real credential.
        let authorizer = GoogleHealthAuthorizer(configuration: .init(clientID: "fixture-client", clientSecret: "fixture+&="),
                                                session: makeSession())
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertFalse(request.url!.absoluteString.contains("client_secret"))
            let body = String(data: try Self.bodyData(from: request), encoding: .utf8)!
            XCTAssertTrue(body.contains("client_secret=fixture%2B%26%3D"))
            XCTAssertTrue(body.contains("client_id=fixture-client"))
            return Self.response(request, status: 400, json: #"{"error":"invalid_client"}"#)
        }
        do {
            _ = try await authorizer.exchangeAuthorizationCode("", verifier: "", redirectURI: URL(string: "http://127.0.0.1:49152/oauth2/callback")!)
            XCTFail("Expected fixture rejection")
        } catch { XCTAssertEqual(error as? GoogleHealthOAuthError, .tokenRequestRejected(status: 400, reason: "invalid_client")) }
        do {
            _ = try await authorizer.refresh(emptyCredentialMetadata())
            XCTFail("Expected fixture rejection")
        } catch { XCTAssertEqual(error as? GoogleHealthOAuthError, .tokenRequestRejected(status: 400, reason: "invalid_client")) }
    }
}
