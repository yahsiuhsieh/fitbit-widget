import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppPreferences: ObservableObject {
    static let menuBarKey = "showInMenuBar"

    @Published private var menuBarIsShown: Bool

    var showInMenuBar: Bool {
        get { menuBarIsShown }
        set {
            // MenuBarExtra writes its current insertion state back while reconciling scenes.
            // Publishing an unchanged value invalidates the App graph and repeats that write.
            guard menuBarIsShown != newValue else { return }
            menuBarIsShown = newValue
            defaults.set(newValue, forKey: Self.menuBarKey)
        }
    }
    @Published private(set) var loginStatus: SMAppService.Status
    @Published private(set) var isChangingLogin = false
    @Published private(set) var loginError: String?

    private let defaults: UserDefaults
    private let status: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () async throws -> Void

    init(defaults: UserDefaults = .standard,
         status: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () async throws -> Void = { try await SMAppService.mainApp.unregister() }) {
        self.defaults = defaults
        self.status = status
        self.register = register
        self.unregister = unregister
        menuBarIsShown = Self.menuBarEnabled(in: defaults)
        loginStatus = status()
        // Reading preferences must never register a login item.
    }

    static func menuBarEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: menuBarKey) == nil || defaults.bool(forKey: menuBarKey)
    }

    func refreshLoginStatus() {
        let currentStatus = status()
        if currentStatus != loginStatus { loginStatus = currentStatus }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isChangingLogin else { return }
        isChangingLogin = true
        loginError = nil
        Task {
            defer { isChangingLogin = false; refreshLoginStatus() }
            do {
                if enabled { try register() }
                else { try await unregister() }
            } catch {
                loginError = "Launch at Login could not be changed. Review Login Items in System Settings."
            }
        }
    }
}
