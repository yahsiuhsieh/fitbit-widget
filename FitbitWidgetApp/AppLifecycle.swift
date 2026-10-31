import AppKit
import Combine
import SwiftUI

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate, ObservableObject {
    let model: CompanionAppModel
    private(set) var launchedAtLogin = false
    private var hasPresentedStatus = false
    private var openStatus: (() -> Void)?
    private var pendingStatusRequest = false
    private var explicitStatusRequested = false
    private var dismissInitialStatus: (() -> Void)?
    private let isLoginLaunch: () -> Bool
    private let menuBarEnabled: () -> Bool

    override convenience init() {
        self.init(model: CompanionAppModel(), isLoginLaunch: {
            let event = NSAppleEventManager.shared().currentAppleEvent
            return event?.eventID == kAEOpenApplication
                && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        }, menuBarEnabled: { AppPreferences.menuBarEnabled(in: .standard) })
    }

    init(model: CompanionAppModel, isLoginLaunch: @escaping () -> Bool,
         menuBarEnabled: @escaping () -> Bool) {
        self.model = model
        self.isLoginLaunch = isLoginLaunch
        self.menuBarEnabled = menuBarEnabled
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        detectLoginLaunch()
    }

    private func detectLoginLaunch() {
        launchedAtLogin = launchedAtLogin || isLoginLaunch()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        detectLoginLaunch()
        dismissStatusForLoginIfNeeded()
        model.startObserving()
        model.syncOnLaunch()
    }

    func applicationDidBecomeActive(_ notification: Notification) { model.syncOnLaunch() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openStatusWindow()
        return openStatus == nil
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: Self.isStatusURL) { openStatusWindow() }
    }

    static func isStatusURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "fitbitwidget" && url.host?.lowercased() == "status"
    }

    // Run from SwiftUI's first onAppear (before the first frame), using native scene actions.
    // No delayed window hiding or activation-policy changes.
    func statusDidAppear(open: @escaping () -> Void, dismiss: @escaping () -> Void) {
        detectLoginLaunch()
        openStatus = open
        guard !hasPresentedStatus else { return }
        hasPresentedStatus = true
        dismissInitialStatus = dismiss
        if pendingStatusRequest { pendingStatusRequest = false; open() }
        else { dismissStatusForLoginIfNeeded() }
    }

    private func dismissStatusForLoginIfNeeded() {
        guard launchedAtLogin, menuBarEnabled(), !explicitStatusRequested,
              let dismissInitialStatus else { return }
        self.dismissInitialStatus = nil
        dismissInitialStatus()
    }

    func openStatusWindow() {
        explicitStatusRequested = true
        dismissInitialStatus = nil
        if let openStatus { openStatus() }
        else { pendingStatusRequest = true }
    }
}

// MenuBarExtra's window is retained across openings. Observe its native key-window events
// instead of treating SwiftUI onAppear as an event for every menu-bar click.
struct NativeWindowObserver: NSViewRepresentable {
    let visibilityChanged: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.visibilityChanged = visibilityChanged
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.visibilityChanged = visibilityChanged
    }

    final class ObserverView: NSView {
        var visibilityChanged: ((Bool) -> Void)?
        private var observations = Set<AnyCancellable>()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.removeAll()
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.willCloseNotification] {
                NotificationCenter.default.publisher(for: name, object: window)
                    .sink { [weak self] notification in
                        let visible = notification.name == NSWindow.didBecomeKeyNotification
                        Task { @MainActor [weak self] in self?.visibilityChanged?(visible) }
                    }
                    .store(in: &observations)
            }
            Task { @MainActor [weak self, weak window] in
                self?.visibilityChanged?(window?.isKeyWindow == true)
            }
        }
    }
}
