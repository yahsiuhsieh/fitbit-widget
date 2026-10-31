import Combine
import AppKit
import Foundation
import WidgetKit

@MainActor
final class CompanionAppModel: ObservableObject {
    enum Activity: Equatable { case idle, connecting, refreshing }

    @Published private(set) var state: SharedWidgetState
    @Published private(set) var activity = Activity.idle
    @Published var message: String?
    @Published private(set) var evaluationDate: Date

    private let sharedStore: SharedWidgetStore?
    private let tokenStore: () throws -> OAuthTokenStore
    private let configuration: () throws -> GoogleHealthConfiguration
    private let session: URLSession
    private let authorize: @MainActor (GoogleHealthAuthorizer) async throws -> OAuthTokenSet?
    private let reloadWidget: () -> Void
    private let now: () -> Date
    private let syncer: HealthSync
    private var task: Task<Void, Never>?
    private var operationID = UUID()
    private var sharedStateObserver: SharedStateObserver?
    private var observations = Set<AnyCancellable>()
    private var presentationTask: Task<Void, Never>?
    private var isPopoverVisible = false
    private var isSettingsVisible = false
    private var isObserving = false

    init(
        sharedStore: SharedWidgetStore? = SharedWidgetStore(),
        tokenStore: @escaping () throws -> OAuthTokenStore = { OAuthTokenStore(keychain: try SharedKeychain()) },
        configuration: @escaping () throws -> GoogleHealthConfiguration = { try .load() },
        session: URLSession = GoogleHealthHTTP.makeSession(),
        authorize: @escaping @MainActor (GoogleHealthAuthorizer) async throws -> OAuthTokenSet? = { try await $0.authorize() },
        reloadWidget: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: SharedConfiguration.widgetKind) },
        now: @escaping () -> Date = Date.init
    ) {
        self.sharedStore = sharedStore
        self.tokenStore = tokenStore
        self.configuration = configuration
        self.session = session
        self.authorize = authorize
        self.reloadWidget = reloadWidget
        self.now = now
        evaluationDate = now()
        state = sharedStore?.load() ?? .initial
        syncer = HealthSync(store: sharedStore, tokenStore: tokenStore, configuration: configuration,
                            session: session, now: now, reload: reloadWidget)
    }

    private var isPreview: Bool { ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" }
    var hasSharedStore: Bool { sharedStore != nil && !isPreview }
    var isConnected: Bool { state.hasVerifiedIdentity }
    var needsReconnection: Bool {
        if state.sync.reconnectRequired { return true }
        guard case let .data(data) = state.content else { return false }
        return data.lastSyncIssue == .reconnectRequired
    }

    var lastSuccessfulUpdate: Date? {
        guard state.hasVerifiedIdentity, case let .data(data) = state.content else { return nil }
        return data.snapshot.lastSuccessfulUpdate
    }

    var resolvedSnapshot: ResolvedHealthSnapshot? {
        guard case let .data(data) = state.content else { return nil }
        let snapshot = state.hasVerifiedIdentity ? data.snapshot.applyingPermissions(state.permissions) : data.snapshot
        return snapshot.resolved(at: evaluationDate, calendar: SharedConfiguration.localCalendar)
    }

    var canRefresh: Bool {
        activity == .idle && hasSharedStore && isConnected && !needsReconnection
            && state.selection.metrics.contains(where: state.permissions.allows)
            && (state.sync.nextAttempt.map { $0 <= evaluationDate } ?? true)
    }

    var refreshHelp: String {
        if needsReconnection { return "Reconnect in Settings to refresh." }
        if let retry = state.sync.nextAttempt, retry > evaluationDate {
            return "Try again after \(retry.formatted(date: .omitted, time: .shortened))."
        }
        return "Refresh selected Google Health metrics."
    }

    func startObserving() {
        guard !isObserving, !isPreview else { return }
        isObserving = true
        if let sharedStore {
            do {
                sharedStateObserver = try SharedStateObserver(directory: sharedStore.fileURL.deletingLastPathComponent()) { [weak self] in
                    self?.reloadSharedState()
                }
            } catch { message = "Shared updates could not be observed. Reopen the popover to load the latest data." }
        }
        // Subscribe before reading, so a concurrent Extension commit cannot fall into a gap.
        reloadSharedState()
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in Task { @MainActor in self?.reloadSharedState() } }
                .store(in: &observations)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.reloadSharedState() } }
            .store(in: &observations)
    }

    func reloadSharedState() {
        let latest = sharedStore?.load() ?? .initial
        if latest != state { state = latest; message = nil }
        evaluationDate = now()
        schedulePresentationTransition()
    }

    func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible else { return }
        isPopoverVisible = visible
        if visible { syncOnLaunch() }
        else { schedulePresentationTransition() }
    }

    func setSettingsVisible(_ visible: Bool) {
        isSettingsVisible = visible
        reloadSharedState()
    }

    private func schedulePresentationTransition() {
        presentationTask?.cancel()
        presentationTask = nil
        guard isPopoverVisible || isSettingsVisible else { return }
        var dates: [Date] = []
        if isPopoverVisible, case let .data(data) = state.content {
            dates = data.snapshot.transitionDates(after: evaluationDate, calendar: SharedConfiguration.localCalendar)
        }
        if isPopoverVisible {
            let calendar = SharedConfiguration.localCalendar
            if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: evaluationDate)) {
                dates.append(midnight) // The header date also changes when every reading is missing.
            }
        }
        if let retry = state.sync.nextAttempt, retry > evaluationDate { dates.append(retry) }
        guard let next = dates.min() else { return }
        let delay = max(0, next.timeIntervalSince(now())) + 0.05
        presentationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            self?.reloadSharedState() // Presentation only; never a scheduled API request.
        }
    }

    var connectionTitle: String {
        if activity == .connecting { return "Connecting…" }
        if activity == .refreshing { return "Refreshing…" }
        if needsReconnection { return "Reconnect Required" }
        if case let .data(data) = state.content, let issue = data.lastSyncIssue {
            return issue == .offline ? "Offline" : "Update Failed"
        }
        switch state.content {
        case .unconnected: return "Not Connected"
        case .accountNotLinked: return "Google Health Profile Required"
        case .initialSyncFailed: return "Connected · Initial Load Failed"
        case .data:
            if !isConnected { return "Development Preview" }
            if state.permissions.grantedMetrics.isEmpty { return "Connected · Permission Required" }
            return state.permissions.isPartial ? "Connected · Partial Authorization" : "Connected"
        }
    }

    var connectionDetail: String {
        guard hasSharedStore else {
            return "Shared health data is unavailable in this build. Reinstall it or contact the developer."
        }
        if activity == .connecting { return "Complete authorization in your browser." }
        if activity == .refreshing { return "Loading the selected Google Health metrics." }
        if needsReconnection { return "Connect Google Health again to continue updating your health data." }
        if case let .data(data) = state.content, let issue = data.lastSyncIssue {
            return issue == .offline
                ? "You’re offline. Valid cached metrics remain available in the Menu Bar and Widget."
                : "The last update failed. Valid cached metrics were kept; try Refresh Now when available."
        }
        switch state.content {
        case .unconnected: return "Connect Google Health to see your metrics in the Menu Bar or optional Widget."
        case .accountNotLinked:
            return "Use the same Google Account to set up Google Health on a compatible phone, then connect again."
        case .initialSyncFailed:
            return "Your Google Health profile was verified, but the initial data request did not complete."
        case .data:
            if !isConnected { return "Sample values are local and are not connected to Google Health." }
            if state.permissions.grantedMetrics.count < 4 {
                return "Granted metrics remain available. Other metrics require permission."
            }
            return "The Menu Bar checks for updates when opened. An installed Widget updates when macOS allows it."
        }
    }

    func startConnection() {
        guard activity == .idle, hasSharedStore else { return }
        message = nil
        activity = .connecting
        let id = UUID()
        operationID = id
        task = Task { [weak self] in await self?.connect(id: id) }
    }

    func cancelActivity() {
        operationID = UUID()
        task?.cancel()
        syncer.cancel()
        task = nil
        activity = .idle
        message = nil
    }

    func syncOnLaunch() {
        reloadSharedState()
        if canRefresh { refresh(.launch) }
    }

    func refresh(_ reason: SyncReason = .manual) {
        reloadSharedState()
        guard canRefresh else { return }
        message = nil
        activity = .refreshing
        let id = UUID()
        operationID = id
        task = Task { [weak self] in await self?.refreshData(id: id, reason: reason) }
    }

    func updateSelection(_ metric: MetricKind, isSelected: Bool) {
        guard activity == .idle, state.permissions.allows(metric), isConnected else { return }
        var metrics = Set(state.selection.metrics)
        if isSelected { metrics.insert(metric) } else { metrics.remove(metric) }
        guard let selection = MetricSelection(metrics) else { return }
        do {
            guard let sharedStore else { return }
            state = try sharedStore.update { current in
                var metadata = current.sync
                if metadata.lastSyncedSelection == nil { metadata.lastSyncedSelection = current.selection }
                current = current.replacing(selection: selection, sync: metadata)
            }
            reloadWidget()
            refresh(.selection)
        } catch { message = "Changes could not be saved. Try again." }
    }

    func resetLocalData() {
        cancelActivity()
        var failed = false
        do {
            if let sharedStore { try sharedStore.clear(removingTokens: { try tokenStore().clear() }) }
            else { try tokenStore().clear() }
        } catch { failed = true }
        state = sharedStore?.load() ?? .initial
        reloadWidget()
        message = failed ? "Some local connection data could not be removed. Try Delete Local Data again." : nil
    }

    #if DEBUG
    func loadDevelopmentPreview() {
        guard activity == .idle, !isConnected else { return }
        let sample = Build2MockData.state(selection: state.selection)
        do {
            try persist(SharedWidgetState(selection: sample.selection, content: sample.content))
        } catch { message = "Sample data could not be saved." }
    }
    #endif

    private func finishActivity(id: UUID) {
        guard operationID == id else { return }
        activity = .idle
        task = nil
    }

    private func connect(id: UUID) async {
        defer { finishActivity(id: id) }
        var verified = false
        var checkingIdentity = false
        do {
            let configuration = try configuration()
            let store = try tokenStore()
            let priorTokens = try store.load()
            guard let tokens = try await authorize(GoogleHealthAuthorizer(configuration: configuration, session: session)) else {
                return // Provider cancellation leaves the previous unconnected/connected state unchanged.
            }
            try Task.checkCancellation()
            let permissions = GoogleHealthScope.permissions(from: tokens.grantedScopes)
            guard let defaultSelection = MetricSelection(permissions.grantedMetrics) else {
                message = "At least one Google Health permission is required to connect."
                return
            }
            let client = GoogleHealthClient(baseURL: configuration.healthAPIBaseURL, session: session)
            checkingIdentity = true
            let identity = try await client.identity(accessToken: tokens.accessToken)
            try Task.checkCancellation()
            state = sharedStore?.load() ?? .initial
            let sameAccount = isConnected && priorTokens?.healthUserID == identity.healthUserID
            let selection = sameAccount ? state.selection : defaultSelection
            verified = true
            if !sameAccount {
                // Clear the previous credential before removing its cache. If either boundary fails,
                // no new identity can accidentally refresh into the previous account's snapshot.
                try sharedStore?.clear(removingTokens: { try store.clear() })
                state = .initial
            }
            guard let sharedStore else { throw GoogleHealthClientError.requestFailed }
            state = try sharedStore.update { current in
                try store.save(tokens.verified(for: identity.healthUserID))
                current = SharedWidgetState(selection: selection,
                                            content: sameAccount ? current.content : .initialSyncFailed,
                                            permissions: permissions, hasVerifiedIdentity: true)
            }
            reloadWidget()
            let result = await syncer.refresh(.connection)
            try Task.checkCancellation()
            apply(result)
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            handle(error, connecting: !verified)
            if checkingIdentity && !verified && (error as? GoogleHealthClientError) != .accountNotLinked {
                message = "Google authorization completed, but Google Health profile verification failed. Confirm Google Health API is enabled for this project and try again."
            }
        }
    }

    private func refreshData(id: UUID, reason: SyncReason) async {
        defer { finishActivity(id: id) }
        let result = await syncer.refresh(reason)
        guard !Task.isCancelled else { return }
        apply(result)
    }

    private func apply(_ result: SyncResult) {
        // Another process may have changed/reset state after this result was formed.
        reloadSharedState()
        guard state == result.state else { return }
        switch result.failure {
        case .offline: message = "You’re offline. Existing health data was kept."
        case .updateFailed: message = "The update did not complete. Existing health data was kept."
        case .reconnectRequired: message = "Connect Google Health again to continue updating your health data."
        case .permissionRequired: message = "Permission Required. Review access or select a granted metric."
        case .configurationUnavailable: message = "Connection is unavailable in this build. Ask the developer to configure Google Health."
        case .storageUnavailable: message = "Changes could not be saved. Try again."
        case nil:
            message = state.sync.nextAttempt.map { $0 > now() ? "An update will be attempted later. Existing health data was kept." : nil } ?? nil
        }
    }

    private func handle(_ error: Error, connecting: Bool) {
        do {
            switch error {
            case GoogleHealthClientError.accountNotLinked:
                // Clear even if one boundary fails. Surface the local failure for recovery.
                var failed = false
                do { try tokenStore().clear() } catch { failed = true }
                try persist(SharedWidgetState(selection: .all, content: .accountNotLinked))
                if failed { message = "Google Health is not linked. Local connection removal failed; try Delete Local Data." }
            case GoogleHealthOAuthError.missingConfiguration, GoogleHealthOAuthError.missingClientSecret:
                message = "Connection is unavailable in this build. Ask the developer to configure Google Health."
            case GoogleHealthClientError.authenticationRequired, GoogleHealthOAuthError.refreshUnavailable:
                try markIssue(.reconnectRequired)
                message = "Connect Google Health again to continue updating your health data."
            case GoogleHealthOAuthError.clientSecretRequired:
                message = "Google rejected the connection configuration. Ask the developer to check the matching Desktop client credentials."
            case GoogleHealthOAuthError.tokenRequestRejected(let status, let reason):
                message = "Google authorization exchange was rejected (\(status), \(reason)). Profile verification has not started."
            case GoogleHealthOAuthError.tokenExchangeFailed:
                message = "Google authorization exchange returned an unusable response. Profile verification has not started."
            case GoogleHealthOAuthError.invalidTokenResponse:
                message = "Google did not provide a refresh token. Connect Google Health again to review consent."
            case GoogleHealthOAuthError.timedOut:
                message = "Connection timed out. Choose Connect Google Health to try again."
            default:
                if !connecting {
                    try markIssue((error as? GoogleHealthClientError) == .offline ? .offline : .updateFailed)
                    message = "The data request did not complete. Existing health data was kept. Try Refresh Now."
                } else {
                    message = "Google Health connection or profile verification failed. Try Connect Google Health again."
                }
            }
        } catch { message = "Changes could not be saved. Try again." }
    }

    private func markIssue(_ issue: SyncIssue) throws {
        guard let sharedStore else { return }
        state = try sharedStore.update { current in
            guard case let .data(data) = current.content else { return }
            current = current.replacing(content: .data(WidgetData(snapshot: data.snapshot, lastSyncIssue: issue)))
        }
        reloadWidget()
    }

    private func persist(_ newState: SharedWidgetState) throws {
        guard let sharedStore else { throw GoogleHealthClientError.requestFailed }
        try sharedStore.save(newState)
        state = newState
        message = nil
        reloadWidget()
    }
}
