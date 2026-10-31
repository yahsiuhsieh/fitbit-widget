import Foundation
import WidgetKit

// Provider Retry-After values are never persisted with an HTTP response or credential.
enum HTTPRetryDelay {
    static func parse(_ value: String?, at now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}

enum SyncReason: Sendable {
    case connection, launch, selection, manual, widget
    var budget: TimeInterval { self == .widget ? 12 : 40 }
    var freshnessInterval: TimeInterval { self == .widget ? 3600 : 300 }
    var forcesFetch: Bool { self == .connection || self == .selection || self == .manual }
}

enum SyncFailure: Equatable, Sendable {
    case offline, updateFailed, reconnectRequired, permissionRequired, configurationUnavailable, storageUnavailable
}

struct SyncResult: Sendable {
    let state: SharedWidgetState
    let didCommit: Bool
    let failure: SyncFailure?
    let coalesced: Bool
}

// One concrete implementation for both processes. MainActor protects per-process task ownership;
// filesystem leases serialize network/refresh work across App and Extension processes.
@MainActor
final class HealthSync {
    static let shared = HealthSync(reload: { WidgetCenter.shared.reloadTimelines(ofKind: SharedConfiguration.widgetKind) })
    private let store: SharedWidgetStore?
    private let tokenStore: () throws -> OAuthTokenStore
    private let configuration: () throws -> GoogleHealthConfiguration
    private let session: URLSession
    private let now: () -> Date
    private let jitter: () -> TimeInterval
    private let reload: () -> Void
    private let renew: @MainActor (GoogleHealthAuthorizer, OAuthTokenSet) async throws -> OAuthTokenSet
    private let budget: (SyncReason) -> TimeInterval
    private var inFlight: Task<SyncResult, Never>?
    private var flightID = UUID()

    init(store: SharedWidgetStore? = SharedWidgetStore(),
         tokenStore: @escaping () throws -> OAuthTokenStore = { OAuthTokenStore(keychain: try SharedKeychain()) },
         configuration: @escaping () throws -> GoogleHealthConfiguration = { try .load() },
         session: URLSession = GoogleHealthHTTP.makeSession(),
         now: @escaping () -> Date = Date.init,
         jitter: @escaping () -> TimeInterval = { Double.random(in: 0...1) },
         reload: @escaping () -> Void = {},
         renew: @escaping @MainActor (GoogleHealthAuthorizer, OAuthTokenSet) async throws -> OAuthTokenSet = { try await $0.refresh($1) },
         budget: @escaping (SyncReason) -> TimeInterval = { $0.budget }) {
        self.store = store; self.tokenStore = tokenStore; self.configuration = configuration
        self.session = session; self.now = now; self.jitter = jitter; self.reload = reload
        self.renew = renew; self.budget = budget
    }

    func cancel() { inFlight?.cancel(); inFlight = nil; flightID = UUID() }

    func refresh(_ reason: SyncReason) async -> SyncResult {
        if let inFlight { return await inFlight.value }
        let id = UUID()
        flightID = id
        let task = Task { await self.boundedRefresh(reason) }
        inFlight = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if flightID == id { inFlight = nil }
        return result
    }

    private func boundedRefresh(_ reason: SyncReason) async -> SyncResult {
        guard let store else { return result(.initial, failure: .storageUnavailable) }
        let initial = store.load()
        guard initial.hasVerifiedIdentity else { return result(initial) }
        let work = Task { try await self.perform(reason, store: store) }
        let timer = Task {
            try? await Task.sleep(for: .seconds(budget(reason)))
            if !Task.isCancelled { work.cancel() }
        }
        defer { timer.cancel() }
        do {
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch {
            if Task.isCancelled { return result(store.load()) }
            // The bounded operation timed out. A reset/new connection cannot receive this error.
            return recordFailure(.updateFailed, expected: initial, permissions: nil, retryAfter: nil, store: store)
        }
    }

    private func perform(_ reason: SyncReason, store: SharedWidgetStore) async throws -> SyncResult {
        let started = now()
        let original = store.load()
        var lease: SharedSyncLease?
        var waited = false
        // A second process waits briefly for the existing commit instead of issuing parallel calls.
        for _ in 0..<30 {
            try Task.checkCancellation()
            lease = try store.acquireSyncLease()
            if lease != nil { break }
            waited = true
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let lease else { return result(store.load(), coalesced: true) }
        defer { withExtendedLifetime(lease) {} }
        var baseline = store.load()
        guard baseline.hasVerifiedIdentity else { return result(baseline) }
        if waited, baseline != original, baseline.connectionID == original.connectionID,
           case let .data(data) = baseline.content, data.snapshot.lastSuccessfulUpdate >= started,
           isFresh(baseline, reason: .launch) {
            return result(baseline, coalesced: true)
        }
        if baseline.sync.reconnectRequired { return result(baseline, failure: .reconnectRequired) }
        if let next = baseline.sync.nextAttempt, next > now() { return result(baseline) }
        if !reason.forcesFetch && isFresh(baseline, reason: reason) { return result(baseline) }

        var permissions = baseline.permissions
        var tokens: OAuthTokenSet
        let credentials: OAuthTokenStore
        let config: GoogleHealthConfiguration
        do {
            credentials = try tokenStore()
            guard let stored = try credentials.load(), stored.healthUserID != nil else {
                return recordFailure(.reconnectRequired, expected: baseline, permissions: nil, retryAfter: nil, store: store)
            }
            tokens = stored
            config = try configuration()
        } catch GoogleHealthOAuthError.missingConfiguration, GoogleHealthOAuthError.missingClientSecret {
            return recordFailure(.configurationUnavailable, expected: baseline, permissions: nil, retryAfter: nil, store: store)
        } catch {
            return recordFailure(.updateFailed, expected: baseline, permissions: nil, retryAfter: nil, store: store)
        }
        let authorizer = GoogleHealthAuthorizer(configuration: config, session: session)
        let client = GoogleHealthClient(baseURL: config.healthAPIBaseURL, session: session)
        var recoveredAuthentication = false
        var retries = 0
        while true {
            try Task.checkCancellation()
            do {
                if tokens.accessTokenExpiration <= now().addingTimeInterval(60) {
                    if let expiry = tokens.refreshTokenExpiration, expiry <= now() {
                        throw GoogleHealthOAuthError.refreshUnavailable
                    }
                    let previousTokens = tokens
                    let refreshed = try await renew(authorizer, tokens)
                    try Task.checkCancellation()
                    var accepted = false
                    baseline = try store.update { current in
                        guard current == baseline, try credentials.load() == previousTokens else { return }
                        try credentials.save(refreshed)
                        let granted = GoogleHealthScope.permissions(from: refreshed.grantedScopes)
                        permissions = MetricPermissions(Set(current.permissions.grantedMetrics).intersection(granted.grantedMetrics))
                        current = current.replacing(permissions: permissions)
                        accepted = true
                    }
                    guard accepted else { return result(store.load(), coalesced: true) }
                    tokens = refreshed
                    recoveredAuthentication = true
                }
                let snapshot = try await fetch(client: client, tokens: tokens, state: baseline)
                try Task.checkCancellation()
                var committed = false
                let updated = try store.update { current in
                    guard current == baseline, try credentials.load() == tokens else { return }
                    var metadata = SyncMetadata.initial
                    metadata.lastSyncedSelection = baseline.selection
                    current = current.replacing(content: .data(WidgetData(snapshot: snapshot, lastSyncIssue: nil)), sync: metadata)
                    committed = true
                }
                if committed { reload() }
                return SyncResult(state: updated, didCommit: committed, failure: nil, coalesced: !committed)
            } catch is CancellationError { throw CancellationError() }
            catch GoogleHealthClientError.authenticationRequired where !recoveredAuthentication {
                // Exactly one on-demand token recovery, never an endless 401/refresh loop.
                recoveredAuthentication = true
                do {
                    let previous = tokens
                    guard store.load() == baseline, try credentials.load() == previous else { return result(store.load(), coalesced: true) }
                    let refreshed = try await renew(authorizer, previous)
                    try Task.checkCancellation()
                    var accepted = false
                    baseline = try store.update { current in
                        guard current == baseline, try credentials.load() == previous else { return }
                        try credentials.save(refreshed)
                        permissions = MetricPermissions(Set(current.permissions.grantedMetrics).intersection(GoogleHealthScope.permissions(from: refreshed.grantedScopes).grantedMetrics))
                        current = current.replacing(permissions: permissions)
                        accepted = true
                    }
                    guard accepted else { return result(store.load(), coalesced: true) }
                    tokens = refreshed
                    continue
                } catch is CancellationError { throw CancellationError() }
                catch {
                    return handle(error, baseline: baseline, permissions: permissions, store: store)
                }
            } catch {
                let delay = retryDelay(error)
                // Only foreground server failures get up to two in-budget retries. Rate limits and
                // long Retry-After values are persisted for later WidgetKit/App opportunities.
                if let delay, reason != .widget, retries < 2,
                   delay < 5, now().timeIntervalSince(started) + pow(2, Double(retries)) + 2 < budget(reason) {
                    let pause = max(delay, pow(2, Double(retries))) + jitter()
                    retries += 1
                    try await Task.sleep(for: .seconds(pause))
                    continue
                }
                return handle(error, baseline: baseline, permissions: permissions, store: store)
            }
        }
    }

    private enum FetchError: Error { case permission(MetricKind), noPermission }

    private func fetch(client: GoogleHealthClient, tokens: OAuthTokenSet, state: SharedWidgetState) async throws -> HealthSnapshot {
        guard state.selection.metrics.contains(where: state.permissions.allows) else { throw FetchError.noPermission }
        let date = now()
        let calendar = SharedConfiguration.localCalendar
        let previous: HealthSnapshot?
        if case let .data(data) = state.content { previous = data.snapshot } else { previous = nil }
        var steps = previous?.steps ?? .noData
        var sleep = previous?.sleep ?? .noData
        var rhr = previous?.restingHeartRate ?? .noData
        var hrv = previous?.hrv ?? .noData
        for metric in state.selection.metrics where state.permissions.allows(metric) {
            try Task.checkCancellation()
            do {
                switch metric {
                case .steps: steps = try await client.steps(for: LocalDay(date: date, calendar: calendar), calendar: calendar, accessToken: tokens.accessToken)
                case .sleep: sleep = try await client.sleep(at: date, calendar: calendar, accessToken: tokens.accessToken)
                case .restingHeartRate: rhr = try await client.restingHeartRate(at: date, calendar: calendar, accessToken: tokens.accessToken)
                case .hrv: hrv = try await client.hrv(at: date, calendar: calendar, accessToken: tokens.accessToken)
                }
            } catch GoogleHealthClientError.missingOAuthScope { throw FetchError.permission(metric) }
        }
        return HealthSnapshot(steps: steps, sleep: sleep, restingHeartRate: rhr, hrv: hrv,
                              lastSuccessfulUpdate: now()).applyingPermissions(state.permissions)
    }

    private func handle(_ error: Error, baseline: SharedWidgetState, permissions: MetricPermissions, store: SharedWidgetStore) -> SyncResult {
        if Task.isCancelled { return result(store.load()) }
        if (error as? GoogleHealthClientError) == .accountNotLinked {
            do {
                var state = store.load()
                state = try store.update { current in
                    guard current == baseline else { return }
                    try? tokenStore().clear()
                    current = SharedWidgetState(selection: .all, content: .accountNotLinked)
                }
                reload()
                return result(state)
            } catch { return result(store.load(), failure: .storageUnavailable) }
        }
        if case let FetchError.permission(metric) = error {
            let remaining = Set(permissions.grantedMetrics).subtracting(GoogleHealthScope.metrics(for: metric))
            return recordFailure(.permissionRequired, expected: baseline, permissions: MetricPermissions(remaining), retryAfter: nil, store: store)
        }
        if case FetchError.noPermission = error { return result(store.load(), failure: .permissionRequired) }
        if (error as? GoogleHealthClientError) == .authenticationRequired || (error as? GoogleHealthOAuthError) == .refreshUnavailable {
            return recordFailure(.reconnectRequired, expected: baseline, permissions: permissions, retryAfter: nil, store: store)
        }
        let offline = (error as? GoogleHealthClientError) == .offline || (error as? URLError)?.code == .notConnectedToInternet
        return recordFailure(offline ? .offline : .updateFailed, expected: baseline, permissions: permissions,
                             retryAfter: retryDelay(error), store: store)
    }

    private func recordFailure(_ failure: SyncFailure, expected: SharedWidgetState, permissions: MetricPermissions?,
                               retryAfter: TimeInterval?, store: SharedWidgetStore) -> SyncResult {
        do {
            let state = try store.update { current in
                guard current == expected else { return }
                var metadata = current.sync
                metadata.failureCount = min(max(0, metadata.failureCount), 19) + 1
                metadata.reconnectRequired = failure == .reconnectRequired
                let backoff = min(3600, 30 * pow(2, Double(metadata.failureCount - 1)) + jitter() * 15)
                metadata.nextAttempt = failure == .permissionRequired ? nil : now().addingTimeInterval(max(retryAfter ?? 0, backoff))
                var content = current.content
                if case let .data(data) = content {
                    let issue: SyncIssue = failure == .offline ? .offline : failure == .reconnectRequired ? .reconnectRequired : .updateFailed
                    content = .data(WidgetData(snapshot: data.snapshot, lastSyncIssue: issue))
                }
                current = current.replacing(content: content, permissions: permissions, sync: metadata)
            }
            reload()
            return result(state, failure: failure)
        } catch { return result(store.load(), failure: .storageUnavailable) }
    }

    private func retryDelay(_ error: Error) -> TimeInterval? {
        if case let GoogleHealthClientError.retryable(after) = error { return after ?? 1 }
        if case let GoogleHealthOAuthError.retryable(after) = error { return after ?? 1 }
        return nil
    }

    private func isFresh(_ state: SharedWidgetState, reason: SyncReason) -> Bool {
        guard case let .data(data) = state.content, data.lastSyncIssue == nil,
              now().timeIntervalSince(data.snapshot.lastSuccessfulUpdate) >= 0,
              now().timeIntervalSince(data.snapshot.lastSuccessfulUpdate) < reason.freshnessInterval,
              state.sync.lastSyncedSelection == nil || state.sync.lastSyncedSelection == state.selection else { return false }
        let calendar = SharedConfiguration.localCalendar
        // A recent pre-midnight commit must not suppress today's first Steps request.
        if state.selection.contains(.steps), state.permissions.allows(.steps),
           LocalDay(date: data.snapshot.lastSuccessfulUpdate, calendar: calendar) != LocalDay(date: now(), calendar: calendar) { return false }
        return true
    }

    private func result(_ state: SharedWidgetState, failure: SyncFailure? = nil, coalesced: Bool = false) -> SyncResult {
        SyncResult(state: state, didCommit: false, failure: failure, coalesced: coalesced)
    }
}
