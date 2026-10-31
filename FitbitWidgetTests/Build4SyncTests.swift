import Foundation
import XCTest

@MainActor
final class Build4SyncTests: XCTestCase {
    func testTwoCallersCoalesceIntoOneCompleteCommit() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        let network = SyncNetwork()
        network.handler = { _ in .json(200, "{}", delay: 0.08) }
        let engine = f.engine(network)
        async let first = engine.refresh(.manual)
        async let second = engine.refresh(.widget)
        let results = await [first, second]
        XCTAssertEqual(network.calls, 1)
        XCTAssertTrue(results.allSatisfy(\.didCommit))
        XCTAssertEqual(f.store.load().sync.lastSyncedSelection?.metrics, [.steps])
        guard case let .data(data) = f.store.load().content else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(data.snapshot.steps, .noData)
        XCTAssertEqual(data.snapshot.lastSuccessfulUpdate, f.clock.date)
        XCTAssertEqual(f.reloads, 1)
    }

    func testRecentCommitSkipsBackgroundCallsButManualRefreshWorks() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        let network = SyncNetwork()
        let engine = f.engine(network)
        let recent = await engine.refresh(.widget)
        XCTAssertFalse(recent.didCommit)
        XCTAssertEqual(network.calls, 0)
        let manual = await engine.refresh(.manual)
        XCTAssertTrue(manual.didCommit)
        XCTAssertEqual(network.calls, 1)
        _ = await engine.refresh(.launch)
        XCTAssertEqual(network.calls, 1)
    }

    func testPermissionAndPreviewStatesNeverTriggerUnauthorizedCalls() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        let network = SyncNetwork()
        try f.store.save(Build2MockData.state())
        _ = await f.engine(network).refresh(.widget)
        XCTAssertEqual(network.calls, 0)
        let verified = SharedWidgetState(selection: .all, content: .initialSyncFailed,
                                        permissions: MetricPermissions([.sleep]), hasVerifiedIdentity: true)
        try f.store.save(verified)
        network.handler = { request in
            XCTAssertTrue(request.url!.path.contains("/sleep/"))
            return .json(200, "{}")
        }
        let result = await f.engine(network).refresh(.manual)
        XCTAssertTrue(result.didCommit)
        XCTAssertEqual(network.calls, 1)
        guard case let .data(data) = result.state.content else { return XCTFail("Expected data") }
        XCTAssertEqual(data.snapshot.steps, .permissionRequired)
        XCTAssertEqual(data.snapshot.sleep, .noData)
    }

    func testRateLimitPersistsRetryAfterAcrossEngineInstances() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        let before = f.store.load()
        let network = SyncNetwork()
        network.handler = { _ in .json(429, "{}", headers: ["Retry-After": "90"]) }
        let failed = await f.engine(network).refresh(.manual)
        XCTAssertEqual(failed.failure, .updateFailed)
        XCTAssertEqual(network.calls, 1)
        XCTAssertEqual(failed.state.sync.nextAttempt, f.clock.date.addingTimeInterval(90))
        XCTAssertEqual(snapshot(failed.state), snapshot(before))
        _ = await f.engine(network).refresh(.manual)
        XCTAssertEqual(network.calls, 1, "A new process/engine must honor shared backoff")
        f.clock.date = f.clock.date.addingTimeInterval(91)
        network.handler = { _ in .json(200, "{}") }
        let recovered = await f.engine(network).refresh(.manual)
        XCTAssertTrue(recovered.didCommit)
        XCTAssertEqual(recovered.state.sync.failureCount, 0)
        XCTAssertNil(recovered.state.sync.nextAttempt)
    }

    func testTransientServerFailureRetriesThenCommitsOnce() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        let network = SyncNetwork()
        network.handler = { _ in .json(network.calls == 1 ? 503 : 200, "{}") }
        let result = await f.engine(network).refresh(.manual)
        XCTAssertTrue(result.didCommit)
        XCTAssertEqual(network.calls, 2)
        XCTAssertEqual(f.reloads, 1)
    }

    func testWidgetDefersTransientFailureWithoutSleepingForRetries() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        f.clock.date = f.clock.date.addingTimeInterval(3601)
        let before = f.store.load()
        let network = SyncNetwork()
        network.handler = { _ in .json(503, "{}") }
        let failed = await f.engine(network).refresh(.widget)
        XCTAssertEqual(network.calls, 1)
        XCTAssertEqual(failed.failure, .updateFailed)
        XCTAssertEqual(snapshot(failed.state), snapshot(before))
        XCTAssertEqual(failed.state.sync.nextAttempt, f.clock.date.addingTimeInterval(30))
        f.clock.date = f.clock.date.addingTimeInterval(31)
        let again = await f.engine(network).refresh(.widget)
        XCTAssertEqual(again.state.sync.failureCount, 2)
        XCTAssertEqual(again.state.sync.nextAttempt, f.clock.date.addingTimeInterval(60))
    }

    func testSecondMetricFailurePreservesEntireSnapshot() async throws {
        let f = try SyncFixture(selection: [.steps, .sleep]); defer { f.clear() }
        let before = f.store.load()
        let network = SyncNetwork()
        network.handler = { request in .json(request.url!.path.contains("/sleep/") ? 400 : 200, "{}") }
        let result = await f.engine(network).refresh(.manual)
        XCTAssertFalse(result.didCommit)
        XCTAssertEqual(result.failure, .updateFailed)
        XCTAssertEqual(snapshot(result.state), snapshot(before))
        XCTAssertEqual(network.calls, 2)
    }

    func testOfflinePreservesCacheAndMarksOfflineWithoutImmediateRetry() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        let before = f.store.load()
        let network = SyncNetwork()
        network.handler = { _ in throw URLError(.notConnectedToInternet) }
        let result = await f.engine(network).refresh(.manual)
        XCTAssertEqual(result.failure, .offline)
        XCTAssertEqual(network.calls, 1)
        XCTAssertEqual(snapshot(result.state), snapshot(before))
        guard case let .data(data) = result.state.content else { return XCTFail("Expected cache") }
        XCTAssertEqual(data.lastSyncIssue, .offline)
    }

    func testExpiredTokenRenewalIsSharedBeforeFetching() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        let expired = f.credentials(expiry: .distantPast)
        try f.tokens.save(expired)
        let network = SyncNetwork()
        let renewed = f.credentials(expiry: f.clock.date.addingTimeInterval(3600))
        var renewals = 0
        let engine = f.engine(network, renew: { _, token in
            XCTAssertEqual(token, expired)
            renewals += 1
            return renewed // Empty credential fields; only expiry metadata is supplied.
        })
        let result = await engine.refresh(.manual)
        XCTAssertTrue(result.didCommit)
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(try f.tokens.load(), renewed)
        XCTAssertEqual(network.calls, 1)
    }

    func test401AllowsOnlyOneRenewalThenRequiresReconnect() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        let before = f.store.load()
        let network = SyncNetwork()
        network.handler = { _ in .json(401, "{}") }
        var renewals = 0
        let engine = f.engine(network, renew: { _, tokens in renewals += 1; return tokens })
        let result = await engine.refresh(.manual)
        XCTAssertEqual(result.failure, .reconnectRequired)
        XCTAssertTrue(result.state.sync.reconnectRequired)
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(network.calls, 2)
        XCTAssertEqual(snapshot(result.state), snapshot(before))
        _ = await engine.refresh(.manual)
        XCTAssertEqual(network.calls, 2, "No automatic calls until reconnection")
    }

    func testRevokedRefreshGrantKeepsValidCacheAndStopsNetwork() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        try f.tokens.save(f.credentials(expiry: .distantPast))
        let before = f.store.load()
        let network = SyncNetwork()
        let result = await f.engine(network, renew: { _, _ in throw GoogleHealthOAuthError.refreshUnavailable }).refresh(.widget)
        // Fresh background state skips refresh; an explicit request must discover the revoked grant.
        XCTAssertNil(result.failure)
        let explicit = await f.engine(network, renew: { _, _ in throw GoogleHealthOAuthError.refreshUnavailable }).refresh(.manual)
        XCTAssertEqual(explicit.failure, .reconnectRequired)
        XCTAssertEqual(snapshot(explicit.state), snapshot(before))
        XCTAssertEqual(network.calls, 0)
    }

    func testResetDuringRequestCannotResurrectCacheOrTokens() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        let network = SyncNetwork()
        let store = f.store
        let memory = f.memory
        network.handler = { _ in
            try store.clear(removingTokens: { memory.write(nil) })
            return .json(200, "{}")
        }
        let result = await f.engine(network).refresh(.manual)
        XCTAssertFalse(result.didCommit)
        XCTAssertEqual(f.store.load(), .initial)
        XCTAssertNil(try f.tokens.load())
    }

    func testSelectionChangeDuringRequestDiscardsOldBatch() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        let network = SyncNetwork()
        let store = f.store
        network.handler = { _ in
            try store.update { $0 = $0.replacing(selection: MetricSelection([.sleep])!) }
            return .json(200, "{}")
        }
        let before = snapshot(f.store.load())
        let result = await f.engine(network).refresh(.manual)
        XCTAssertFalse(result.didCommit)
        XCTAssertEqual(f.store.load().selection.metrics, [.sleep])
        XCTAssertEqual(snapshot(f.store.load()), before)
    }

    func testNewConnectionDuringRequestCannotReceiveOldAccountResult() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        let newState = SharedWidgetState(selection: .all, content: .initialSyncFailed,
                                        permissions: .all, hasVerifiedIdentity: true)
        let store = f.store
        let network = SyncNetwork()
        network.handler = { _ in try store.save(newState); return .json(200, "{}") }
        let result = await f.engine(network).refresh(.manual)
        XCTAssertFalse(result.didCommit)
        XCTAssertEqual(store.load(), newState)
    }

    func testBoundedWidgetRequestPreservesSnapshotOnTimeout() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        f.clock.date = f.clock.date.addingTimeInterval(3601)
        let before = snapshot(f.store.load())
        let network = SyncNetwork()
        network.handler = { _ in .json(200, "{}", delay: 2) }
        let start = Date()
        let result = await f.engine(network, budget: { _ in 0.05 }).refresh(.widget)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertFalse(result.didCommit)
        XCTAssertEqual(snapshot(f.store.load()), before)
    }

    func testMidnightDoesNotSuppressTodaysStepsFetch() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: f.clock.date))!
        f.clock.date = midnight.addingTimeInterval(-1)
        let state = Build2MockData.state(at: f.clock.date, calendar: calendar)
        try f.store.save(SharedWidgetState(selection: MetricSelection([.steps])!, content: state.content,
                                          permissions: .all, hasVerifiedIdentity: true))
        f.clock.date = midnight
        let network = SyncNetwork()
        let result = await f.engine(network).refresh(.widget)
        XCTAssertTrue(result.didCommit)
        XCTAssertEqual(network.calls, 1)
        XCTAssertEqual(snapshot(result.state)?.steps, .noData)
    }

    func testKernelLeaseExcludesSeparateStoreInstancesAndReleases() throws {
        let f = try SyncFixture(); defer { f.clear() }
        let second = SharedWidgetStore(containerURL: f.directory)
        var lease = try XCTUnwrap(f.store.acquireSyncLease()) as SharedSyncLease?
        XCTAssertNil(try second.acquireSyncLease())
        withExtendedLifetime(lease) {}
        lease = nil
        XCTAssertNotNil(try second.acquireSyncLease())
    }

    func testTimelineKeepsMidnightAndHonorsLongRetryAfter() throws {
        let f = try SyncFixture(); defer { f.clear() }
        var metadata = SyncMetadata.initial
        metadata.nextAttempt = f.clock.date.addingTimeInterval(7200)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let state = f.store.load().replacing(sync: metadata)
        let schedule = WidgetTimelineSchedule.make(state: state, startingAt: f.clock.date, calendar: calendar)
        XCTAssertEqual(schedule.refreshDate, metadata.nextAttempt)
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: f.clock.date))!
        XCTAssertTrue(schedule.items.contains(where: { $0.date == midnight }))
        XCTAssertEqual(HTTPRetryDelay.parse("12"), 12)
        XCTAssertNil(HTTPRetryDelay.parse("nan"))
        XCTAssertNil(HTTPRetryDelay.parse("-1"))
        XCTAssertEqual(HTTPRetryDelay.parse("Sat, 31 Oct 2026 00:00:00 GMT", at: ISO8601DateFormatter().date(from: "2026-10-30T23:59:00Z")!), 60)
    }

    func testSeparateEngineUsesCommitFromExistingCrossProcessLease() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        var lease: SharedSyncLease? = try XCTUnwrap(f.store.acquireSyncLease())
        let network = SyncNetwork()
        let engine = f.engine(network)
        let pending = Task { await engine.refresh(.manual) }
        try await Task.sleep(for: .milliseconds(150))
        try f.store.update { current in
            var metadata = SyncMetadata.initial
            metadata.lastSyncedSelection = current.selection
            current = current.replacing(sync: metadata)
        }
        withExtendedLifetime(lease) {}
        lease = nil
        let result = await pending.value
        XCTAssertTrue(result.coalesced)
        XCTAssertEqual(network.calls, 0)
    }

    func testNarrowedRefreshGrantDisablesMetricsBeforeDataFetch() async throws {
        let f = try SyncFixture(selection: [.steps, .sleep]); defer { f.clear() }
        try f.tokens.save(f.credentials(expiry: .distantPast))
        let network = SyncNetwork()
        network.handler = { request in
            XCTAssertTrue(request.url!.path.contains("/sleep/"))
            return .json(200, "{}")
        }
        let result = await f.engine(network, renew: { _, token in
            OAuthTokenSet(accessToken: "", refreshToken: "", accessTokenExpiration: .distantFuture,
                          refreshTokenExpiration: nil, grantedScopes: [GoogleHealthScope.sleep], healthUserID: token.healthUserID)
        }).refresh(.manual)
        XCTAssertTrue(result.didCommit)
        XCTAssertEqual(result.state.permissions.grantedMetrics, [.sleep])
        XCTAssertEqual(result.state.selection.metrics, [.steps, .sleep])
        XCTAssertEqual(snapshot(result.state)?.steps, .permissionRequired)
        XCTAssertEqual(network.calls, 1)
    }

    func testCancellationReleasesLeaseWithoutMarkingUpdateFailed() async throws {
        let f = try SyncFixture(); defer { f.clear() }
        let before = f.store.load()
        let network = SyncNetwork()
        network.handler = { _ in .json(200, "{}", delay: 2) }
        let engine = f.engine(network)
        let pending = Task { await engine.refresh(.manual) }
        while network.calls == 0 { await Task.yield() }
        engine.cancel()
        let result = await pending.value
        XCTAssertFalse(result.didCommit)
        XCTAssertNil(result.failure)
        XCTAssertEqual(f.store.load(), before)
        XCTAssertNotNil(try f.store.acquireSyncLease())
    }

    func testMidnightTimelineUsesCivilDayAcrossFallDSTTransition() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let date = ISO8601DateFormatter().date(from: "2026-11-01T05:30:00Z")!
        let midnight = ISO8601DateFormatter().date(from: "2026-11-02T06:00:00Z")!
        let state = Build2MockData.state(at: date, calendar: calendar)
        let schedule = WidgetTimelineSchedule.make(state: state, startingAt: date, calendar: calendar)
        XCTAssertTrue(schedule.items.contains(where: { $0.date == midnight }))
        XCTAssertEqual(midnight.timeIntervalSince(date), 24.5 * 3600)
        XCTAssertEqual(snapshot(state)?.resolved(at: midnight, calendar: calendar).steps, .noData)
    }

    private func snapshot(_ state: SharedWidgetState) -> HealthSnapshot? {
        if case let .data(data) = state.content { return data.snapshot }
        return nil
    }
}

@MainActor
private final class SyncFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: SharedWidgetStore
    let memory = SyncMemory()
    let clock = SyncClock()
    var reloads = 0
    var tokens: OAuthTokenStore {
        OAuthTokenStore(read: { self.memory.read() }, write: { self.memory.write($0) }, delete: { self.memory.write(nil) })
    }
    init(selection: [MetricKind] = [.steps]) throws {
        store = SharedWidgetStore(containerURL: directory)
        try tokens.save(credentials())
        let sample = Build2MockData.state(at: clock.date)
        try store.save(SharedWidgetState(selection: MetricSelection(selection)!, content: sample.content,
                                         permissions: .all, hasVerifiedIdentity: true))
    }
    func credentials(expiry: Date = .distantFuture) -> OAuthTokenSet {
        OAuthTokenSet(accessToken: "", refreshToken: "", accessTokenExpiration: expiry,
                      refreshTokenExpiration: nil, grantedScopes: Set(GoogleHealthScope.requested), healthUserID: "health-fixture")
    }
    func engine(_ network: SyncNetwork,
                renew: @escaping @MainActor (GoogleHealthAuthorizer, OAuthTokenSet) async throws -> OAuthTokenSet = { try await $0.refresh($1) },
                budget: @escaping (SyncReason) -> TimeInterval = { $0.budget }) -> HealthSync {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncProtocol.self]
        SyncProtocol.network = network
        return HealthSync(store: store, tokenStore: { self.tokens },
                          configuration: { .init(clientID: "") }, session: URLSession(configuration: config),
                          now: { self.clock.date }, jitter: { 0 }, reload: { self.reloads += 1 }, renew: renew, budget: budget)
    }
    func clear() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private final class SyncClock { var date = ISO8601DateFormatter().date(from: "2026-10-30T18:00:00Z")! }

private final class SyncMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func read() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ data: Data?) { lock.lock(); defer { lock.unlock() }; value = data }
}

private final class SyncNetwork: @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: String
        let headers: [String: String]
        let delay: TimeInterval
        static func json(_ status: Int, _ body: String, headers: [String: String] = [:], delay: TimeInterval = 0) -> Self {
            Self(status: status, body: body, headers: headers, delay: delay)
        }
    }
    private let lock = NSLock()
    private var count = 0
    var handler: @Sendable (URLRequest) throws -> Reply = { _ in .json(200, "{}") }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func reply(_ request: URLRequest) throws -> Reply {
        lock.lock(); count += 1; lock.unlock()
        return try handler(request)
    }
}

private final class SyncProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var network: SyncNetwork?
    private let lock = NSLock()
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let reply = try Self.network!.reply(request)
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
                lock.lock(); defer { lock.unlock() }
                guard !cancelled else { return }
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { lock.lock(); cancelled = true; lock.unlock() }
}
