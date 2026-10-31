import Combine
import Foundation
import ServiceManagement
import SwiftUI
import XCTest

@MainActor
final class Build45MenuBarTests: XCTestCase {
    func testNativeUpdateAgeHasMinutePrecisionAndNoSeconds() throws {
        let update = Date(timeIntervalSince1970: 1_700_000_000)
        let style = SystemFormatStyle.DateReference(to: update, allowedFields: [.minute], maxFieldCount: 1, thresholdField: .year)
            .locale(Locale(identifier: "en_US"))
        for (age, expected) in [(0.0, "now"), (29, "now"), (30, "1 minute ago"),
                                (75, "1 minute ago"), (90, "2 minutes ago"), (3600, "60 minutes ago")] {
            XCTAssertEqual(String(style.format(update.addingTimeInterval(age)).characters), expected)
        }
        let encoded = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(SystemFormatStyle.DateReference.self, from: encoded)
        XCTAssertEqual(String(decoded.format(update.addingTimeInterval(75)).characters), "1 minute ago")
    }

    func testNativeInsertionWritebackDoesNotRepublishUnchangedPreferences() throws {
        let suite = "Build45.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var serviceStatus = SMAppService.Status.notRegistered
        let preferences = AppPreferences(defaults: defaults, status: { serviceStatus })
        var updates = 0
        let subscription = preferences.objectWillChange.sink { updates += 1 }

        // Simulate MenuBarExtra's insertion-state writeback during scene reconciliation.
        for _ in 0..<20 { preferences.showInMenuBar = true }
        XCTAssertEqual(updates, 0, "Same-value writeback must not trigger another scene update")
        preferences.showInMenuBar = false
        XCTAssertEqual(updates, 1)
        for _ in 0..<20 { preferences.showInMenuBar = false }
        XCTAssertEqual(updates, 1)
        XCTAssertFalse(AppPreferences.menuBarEnabled(in: defaults))
        preferences.showInMenuBar = true
        XCTAssertEqual(updates, 2)
        XCTAssertTrue(AppPreferences.menuBarEnabled(in: defaults))

        preferences.refreshLoginStatus()
        XCTAssertEqual(updates, 2)
        serviceStatus = .requiresApproval
        preferences.refreshLoginStatus()
        XCTAssertEqual(updates, 3)
        preferences.refreshLoginStatus()
        XCTAssertEqual(updates, 3)
        withExtendedLifetime(subscription) {}
    }

    func testLoginWindowSuppressionAndExplicitReopenAreIndependentOfConnection() {
        let model = CompanionAppModel(sharedStore: nil)
        let lifecycle = AppLifecycle(model: model, isLoginLaunch: { true }, menuBarEnabled: { true })
        var dismissals = 0
        var openings = 0
        lifecycle.statusDidAppear(open: { openings += 1 }, dismiss: { dismissals += 1 })
        XCTAssertEqual(dismissals, 1)
        lifecycle.openStatusWindow()
        lifecycle.statusDidAppear(open: { openings += 1 }, dismiss: { dismissals += 1 })
        XCTAssertEqual(openings, 1)
        XCTAssertEqual(dismissals, 1, "Explicit reopening must not dismiss the settings window again")

        let disabled = AppLifecycle(model: model, isLoginLaunch: { true }, menuBarEnabled: { false })
        disabled.statusDidAppear(open: {}, dismiss: { dismissals += 1 })
        XCTAssertEqual(dismissals, 1, "Login with the icon disabled must retain a visible settings window")

        let requested = AppLifecycle(model: model, isLoginLaunch: { true }, menuBarEnabled: { true })
        requested.openStatusWindow() // A Widget URL/reopen may arrive before the scene appears.
        requested.statusDidAppear(open: { openings += 1 }, dismiss: { dismissals += 1 })
        XCTAssertEqual(openings, 2)
        XCTAssertEqual(dismissals, 1)
        XCTAssertTrue(AppLifecycle.isStatusURL(URL(string: "fitbitwidget://status")!))
        XCTAssertFalse(AppLifecycle.isStatusURL(URL(string: "https://status")!))

        var loginEventAvailable = false
        let lateEvent = AppLifecycle(model: model, isLoginLaunch: { loginEventAvailable }, menuBarEnabled: { true })
        lateEvent.statusDidAppear(open: {}, dismiss: { dismissals += 1 })
        XCTAssertEqual(dismissals, 1)
        loginEventAvailable = true
        lateEvent.applicationDidFinishLaunching(Notification(name: Notification.Name("test-launch")))
        XCTAssertEqual(dismissals, 2, "A login event delivered after scene creation must still suppress initial settings")
    }

    func testSettingsRefreshButtonRecoversAfterCooldownWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedWidgetStore(containerURL: directory)
        let sample = Build2MockData.state()
        let deadline = Date().addingTimeInterval(0.15)
        var metadata = SyncMetadata.initial
        metadata.nextAttempt = deadline
        try store.save(SharedWidgetState(selection: sample.selection, content: sample.content,
                                        permissions: .all, hasVerifiedIdentity: true, sync: metadata))
        let model = CompanionAppModel(sharedStore: store, tokenStore: { throw CocoaError(.fileReadUnknown) })
        let ready = expectation(description: "Visible settings cooldown expired")
        let subscription = model.$evaluationDate.filter { $0 >= deadline }.prefix(1).sink { _ in ready.fulfill() }
        model.setSettingsVisible(true)
        XCTAssertFalse(model.canRefresh)
        await fulfillment(of: [ready], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertTrue(model.canRefresh)
        XCTAssertEqual(model.activity, .idle)
        XCTAssertNil(model.message)
        model.setSettingsVisible(false)
    }

    func testMenuBarDefaultsOnAndLoginRegistrationRequiresExplicitAction() async throws {
        let suite = "Build45.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var serviceStatus = SMAppService.Status.notRegistered
        var registrations = 0
        let preferences = AppPreferences(defaults: defaults, status: { serviceStatus }, register: {
            registrations += 1
            serviceStatus = .requiresApproval
        }, unregister: { serviceStatus = .notRegistered })
        XCTAssertTrue(preferences.showInMenuBar)
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(preferences.loginStatus, .notRegistered)

        preferences.showInMenuBar = false
        let restored = AppPreferences(defaults: defaults, status: { serviceStatus })
        XCTAssertFalse(restored.showInMenuBar)
        XCTAssertEqual(registrations, 0)

        let changed = expectation(description: "Explicit login registration completed")
        let subscription = preferences.$isChangingLogin.dropFirst().filter { !$0 }.sink { _ in changed.fulfill() }
        preferences.setLaunchAtLogin(true)
        await fulfillment(of: [changed], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(preferences.loginStatus, .requiresApproval)
        XCTAssertFalse(preferences.showInMenuBar, "Login registration must not enable the icon")

        serviceStatus = .notRegistered // Simulate macOS settings disabling the service.
        preferences.refreshLoginStatus()
        XCTAssertEqual(preferences.loginStatus, .notRegistered)
        XCTAssertEqual(registrations, 1, "Never silently re-register a disabled login item")
    }

    func testLoginFailureDisplaysActualSystemState() async {
        let preferences = AppPreferences(status: { .notRegistered }, register: { throw CocoaError(.fileWriteNoPermission) })
        let changed = expectation(description: "Registration failure surfaced")
        let subscription = preferences.$isChangingLogin.dropFirst().filter { !$0 }.sink { _ in changed.fulfill() }
        preferences.setLaunchAtLogin(true)
        await fulfillment(of: [changed], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(preferences.loginStatus, .notRegistered)
        XCTAssertNotNil(preferences.loginError)
    }

    func testExtensionReplacementDeletionAndRecreationReachAppWithoutRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let appStore = SharedWidgetStore(containerURL: directory)
        let extensionStore = SharedWidgetStore(containerURL: directory)
        let model = CompanionAppModel(sharedStore: appStore, tokenStore: { throw CocoaError(.fileReadUnknown) })
        model.startObserving()

        let first = Build2MockData.state(selection: MetricSelection([.steps])!)
        try await expectState(first, model: model) { try extensionStore.save(first) }
        let second = Build2MockData.state(selection: MetricSelection([.sleep, .hrv])!)
        try await expectState(second, model: model) { try extensionStore.save(second) }
        try await expectState(.initial, model: model) { try extensionStore.clear() }
        try await expectState(first, model: model) { try extensionStore.save(first) }
        XCTAssertEqual(model.activity, .idle)
        XCTAssertNil(model.message, "Observing cache must not touch credentials or the network")
    }

    func testPermissionsFreshnessAndCooldownUseSharedStateAndCurrentTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedWidgetStore(containerURL: directory)
        var date = Date()
        let initialDate = date
        let sample = Build2MockData.state(at: date)
        var metadata = SyncMetadata.initial
        metadata.nextAttempt = date.addingTimeInterval(30)
        let state = SharedWidgetState(selection: .all, content: sample.content,
                                      permissions: MetricPermissions([.sleep]), hasVerifiedIdentity: true, sync: metadata)
        try store.save(state)
        let model = CompanionAppModel(sharedStore: store, now: { date })
        XCTAssertFalse(model.canRefresh)
        XCTAssertEqual(model.resolvedSnapshot?.steps, .permissionRequired)
        date = date.addingTimeInterval(31)
        model.reloadSharedState()
        XCTAssertTrue(model.canRefresh, "Partial permission still permits granted selected metrics")

        date = initialDate.addingTimeInterval(6 * 3600 + 1)
        model.reloadSharedState()
        XCTAssertEqual(model.resolvedSnapshot?.isStale, true)
        metadata.reconnectRequired = true
        try store.save(state.replacing(content: .initialSyncFailed, sync: metadata))
        model.reloadSharedState()
        XCTAssertTrue(model.needsReconnection, "Reconnect must be visible before any snapshot exists")
        XCTAssertFalse(model.canRefresh)
        XCTAssertNil(model.resolvedSnapshot)
        XCTAssertEqual(model.activity, .idle, "Time reevaluation must not schedule a sync")
    }

    func testResetClearsBothSurfacesButPreservesMenuBarPreference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedWidgetStore(containerURL: directory)
        try store.save(Build2MockData.state())
        let suite = "Build45.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults, status: { .notRegistered })
        preferences.showInMenuBar = false
        let tokens = OAuthTokenStore(read: { nil }, write: { _ in }, delete: {})
        let model = CompanionAppModel(sharedStore: store, tokenStore: { tokens })
        model.resetLocalData()
        XCTAssertEqual(model.state, .initial)
        XCTAssertEqual(store.load(), .initial)
        XCTAssertNil(model.resolvedSnapshot)
        XCTAssertFalse(preferences.showInMenuBar)
        XCTAssertFalse(AppPreferences.menuBarEnabled(in: defaults))
    }

    func testPopoverOpenUsesCacheWithoutWidgetOrCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedWidgetStore(containerURL: directory)
        let sample = Build2MockData.state()
        try store.save(SharedWidgetState(selection: sample.selection, content: sample.content,
                                        permissions: .all, hasVerifiedIdentity: true))
        let model = CompanionAppModel(sharedStore: store, tokenStore: { throw CocoaError(.fileReadUnknown) })
        let finished = expectation(description: "Fresh cache skips networking")
        let subscription = model.$activity.dropFirst().filter { $0 == .idle }.sink { _ in finished.fulfill() }
        model.setPopoverVisible(true)
        model.setPopoverVisible(true) // Duplicate native events must not start a second request.
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertNotNil(model.resolvedSnapshot)
        XCTAssertNil(model.message)
        model.setPopoverVisible(false)
        XCTAssertEqual(model.activity, .idle)
    }

    private func expectState(_ state: SharedWidgetState, model: CompanionAppModel,
                             write: () throws -> Void) async throws {
        let changed = expectation(description: "Shared snapshot changed")
        let subscription = model.$state.dropFirst().filter { $0 == state }.prefix(1).sink { _ in changed.fulfill() }
        try write()
        await fulfillment(of: [changed], timeout: 3)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(model.state, state)
    }
}
