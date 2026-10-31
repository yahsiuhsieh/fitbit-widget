# Fitbit Widget

A native macOS 15+ SwiftUI and WidgetKit app for showing selected Google Health metrics in the Menu Bar, a Large desktop widget, or both.

The current milestone contains:

- A native Apple Silicon macOS companion app.
- A Large WidgetKit widget backed by an App Group snapshot.
- A default-enabled native Menu Bar popover using the same selection, snapshot and sync engine; no Widget installation required.
- Independent Show in Menu Bar and opt-in Launch at Login settings, with the regular macOS Dock icon retained.
- Google OAuth 2.0 authorization-code flow with PKCE and a loopback callback.
- Google Health identity checks and one shared App/Widget sync implementation.
- Bounded Widget refresh, shared Keychain token renewal, cross-process refresh coalescing and persisted retry/backoff.
- Steps, sleep, resting heart rate, and HRV layouts.
- Partial-permission, missing, stale, update-failed, account-not-linked, and initial states.

Build #4.5 adds Menu Bar access to Build #4's shared sync. Opening the popover shows cache immediately and checks for an update using the App's five-minute freshness gate. Refresh Now respects existing in-flight work and retry cooldown. Extension writes update an open popover through directory observation; there is no recurring background App polling. The Widget can refresh while the App is closed. It requests approximately hourly timelines, but macOS controls actual execution and can defer updates. Cached values remain visible on failure and expire according to each metric’s valid window. See [`PROJECT.md`](PROJECT.md) for the MVP specification and build order.

## Run locally

1. Open `FitbitWidget.xcodeproj` in Xcode.
2. Select the `FitbitWidget` scheme and **My Mac** destination.
3. Configure your Apple Developer team under **Signing & Capabilities** when testing App Groups or shared Keychain access.
4. Create a Google OAuth client of type **Desktop app**, then put its client ID and matching client secret in `Config/GoogleHealth.local.xcconfig` as described below. Both targets must use the same client configuration.
5. Enable the Google Health API, configure the OAuth consent screen, and add the test Google Account when the app remains in testing.
6. Run the companion app and choose **Connect Google Health**. Use the same Google Account that has a Google Health profile on a compatible phone.
7. Click the heart icon in the menu bar to view your selected metrics. Optionally control-click the desktop, choose **Edit Widgets**, search for **Fitbit Widget**, and add the Large widget.

Closing the settings window keeps the App and Menu Bar running. Settings contains **Show in Menu Bar** (on by default) and **Launch at Login** (off unless explicitly enabled). These settings are independent: an enabled Menu Bar icon only appears while the App runs. Quitting removes it; an installed Widget can still refresh. After a restart, launch the App manually or opt into Launch at Login. Sign Out/Delete Local Data preserves these behavior preferences.

Build #4.5's App/Extension build and 86 local/mock tests pass. An isolated native startup test confirms that MenuBarExtra insertion-state writeback no longer causes an infinite scene update loop. Before considering the milestone validated, check the native popover's dismissal, repeated opening, settings routing, toggle persistence, light/dark appearance, keyboard/VoiceOver and idle use, plus signed login launching on macOS 15+. Actual login-item registration was not changed for testing.

App and Widget use the same local configuration in Debug and Release. Existing local values are preserved; neither credential needs to be pasted into chat or source control.

## Local Desktop client configuration

Open `Config/GoogleHealth.local.xcconfig` and configure the matching Desktop client values:

```xcconfig
GOOGLE_HEALTH_OAUTH_CLIENT_ID = your-client-id.apps.googleusercontent.com
GOOGLE_HEALTH_OAUTH_CLIENT_SECRET = your-desktop-client-secret
```

Paste the value without surrounding quotes. Edit `GoogleHealth.local.xcconfig`, not the tracked `GoogleHealth.xcconfig`: a blank local assignment overrides a value placed in the shared defaults.

The local file is ignored by Git. If it is absent on a new checkout, create it; the tracked `Config/GoogleHealth.xcconfig` includes it optionally for both targets and configurations. Stop and rebuild the App after editing. Do not add the actual value to the Xcode project file, source, or command-line build arguments. The App fails clearly before opening OAuth if its client ID or secret is missing.

This is Google Desktop application configuration, not confidential token storage. Its value is expanded into both built bundles’ Info.plist files and can be extracted from a distributed App. Excluding the source configuration from Git does not hide it in the binary. PKCE and random state remain required. User access/refresh tokens remain exclusively in the shared Keychain. No SDK dependency or backend is required.

For a live smoke test, verify successful authorization, partial authorization, browser cancellation, an account without Google Health setup, and an authorized account with at least one supported metric. Confirm that failed refreshes retain the previous widget snapshot and that **Delete Local Data** removes only this Mac's local tokens and snapshot.

## Requirements

- Apple Silicon Mac
- macOS 15 or later
- Xcode with the macOS 15 SDK or later

## macOS App Group provisioning

Both App and Widget targets set `REGISTER_APP_GROUPS = YES` with automatic signing. On macOS 15 and later, the `group.com.yahsiu.FitbitWidget` entitlement must also be authorized in each process's embedded provisioning profile. A valid code signature alone does not establish runtime container access. Let Xcode update profiles when prompted; the existing group identifier and shared Keychain group stay unchanged.

If the App is connected but the Widget shows Connect Google Health, check for container-access denials before clearing data or reconnecting. The confirmed development fix was to obtain profiles containing `com.apple.security.application-groups`, rebuild, restart the App/Widget processes, and reload the timeline. See [Apple's container authorization guidance](https://developer.apple.com/documentation/xcode/accessing-app-group-containers).

## Refresh behavior

- Widget requests have a 12-second overall budget; App requests have a 40-second budget. Preview timelines never perform networking.
- Kernel file locks coalesce work across processes; the shared snapshot and token checks reject results after reset, selection change or reconnection. App selection/reset and token writes use short state transactions.
- Foreground transient server failures receive at most two in-budget exponential retries with jitter. Rate limits honor Retry-After (at least 30 seconds); subsequent backoff is stored in the App Group and grows up to one hour, or longer when required by Retry-After. Manual refresh respects that cooldown.
- One token recovery is allowed after a 401. A failed/expired refresh grant marks Reconnect Required while retaining still-valid cached values. Partial/revoked permissions retain Widget positions and never become missing data.
- Only a complete successful selected/authorized batch advances Last Successful Update. Empty results commit Missing Data; partial/error/cancelled batches do not replace the snapshot. A local-midnight timeline entry invalidates yesterday's Steps, including across DST.
- Existing credentials and Build #3 snapshots remain usable. No health-history store, background daemon, backend, analytics or new dependencies were introduced. Remote revocation and final release/privacy work remain Build #5.

Tests use intercepted URLSession requests, empty credential-field metadata fixtures, injected token renewal and temporary shared stores; they consume no live Google quota. Signed extension token refresh and real WidgetKit cadence should still be checked on the tester's Mac outside the debugger. Closing the App must not be interpreted as a promise that macOS will run the Widget at an exact time.
