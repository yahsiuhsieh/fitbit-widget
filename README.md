# Fitbit Widget

A native macOS 14+ SwiftUI and WidgetKit app for showing selected Google Health metrics in a Large desktop widget.

The current milestone contains:

- A native Apple Silicon macOS companion app.
- A Large WidgetKit widget with mock data.
- Steps, sleep, resting heart rate, and HRV layouts.
- Missing, stale, offline, update-failed, reconnect-required, and initial states.

Google OAuth, Google Health networking, shared persistence, and production sync are not implemented yet. See [`PROJECT.md`](PROJECT.md) for the MVP specification and build order.

## Run locally

1. Open `FitbitWidget.xcodeproj` in Xcode.
2. Select the `FitbitWidget` scheme and **My Mac** destination.
3. Configure your Apple Developer team under **Signing & Capabilities** when testing App Groups or shared Keychain access.
4. Run the companion app.
5. Control-click the desktop, choose **Edit Widgets**, search for **Fitbit Widget**, and add the Large widget.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Xcode with the macOS 14 SDK or later
