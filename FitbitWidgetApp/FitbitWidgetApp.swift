import SwiftUI

@main
struct FitbitWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var preferences = AppPreferences()

    var body: some Scene {
        Window("Fitbit Widget", id: "status") {
            StatusWindowContent(model: lifecycle.model, preferences: preferences, lifecycle: lifecycle)
        }
        .defaultSize(width: 560, height: 700)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…", action: lifecycle.openStatusWindow)
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra("Fitbit Widget", systemImage: "heart.text.square.fill",
                     isInserted: $preferences.showInMenuBar) {
            MenuBarHealthView(model: lifecycle.model, openSettings: lifecycle.openStatusWindow)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct StatusWindowContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject var model: CompanionAppModel
    @ObservedObject var preferences: AppPreferences
    let lifecycle: AppLifecycle

    var body: some View {
        CompanionAppView(model: model, preferences: preferences)
            .background(NativeWindowObserver { visible in
                model.setSettingsVisible(visible)
                if visible { preferences.refreshLoginStatus() }
            }.frame(width: 0, height: 0))
            .onAppear {
                lifecycle.statusDidAppear(open: {
                    openWindow(id: "status")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }, dismiss: { dismissWindow(id: "status") })
            }
            .onOpenURL { url in
                guard AppLifecycle.isStatusURL(url) else { return }
                lifecycle.openStatusWindow()
            }
    }
}
