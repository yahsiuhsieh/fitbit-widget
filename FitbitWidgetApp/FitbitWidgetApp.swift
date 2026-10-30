import SwiftUI

@main
struct FitbitWidgetApp: App {
    var body: some Scene {
        WindowGroup {
            CompanionAppView()
        }
        .defaultSize(width: 560, height: 420)
        .windowResizability(.contentSize)
    }
}
