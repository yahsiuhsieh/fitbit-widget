# Fitbit Mac Widget

## MVP Goal

Build a polished, lightweight native macOS experience that shows selected Google Health metrics in a desktop Widget, a Menu Bar popover, or both, without requiring the user to open a dashboard.

**Ideal flow:** Install the Mac app through TestFlight → connect Google Health → review permissions and metric selection → use the default-enabled Menu Bar and/or add the Widget from the macOS Widget Gallery. Neither surface requires the other.

## Product Boundary

- **Platform:** Apple Silicon Mac running macOS 15 or later.
- **Distribution:** Small external TestFlight beta; not a public App Store launch.
- **Widget:** One Large WidgetKit card for the desktop or Notification Center; never always-on-top.
- **Menu Bar:** One optional icon and compact native popover hosted by the running Companion App; enabled by default. Widget installation is optional.
- **Account:** One connected Google account at a time.
- **Language:** English UI. Dates, times, number formatting, and 12/24-hour time follow macOS locale settings.
- **Design:** Calm, information-dense, accessible, and legible in light, dark, and macOS widget rendering modes.

## Widget Experience

- Default to all four authorized metrics: Steps, Sleep, Resting Heart Rate, and HRV.
- Let the user select 1–4 metrics in the Companion App. Use the fixed order above; do not support drag ordering or per-Widget configuration.
- All Widget instances and the Menu Bar share one selection; permissions and metric semantics apply equally to both surfaces.
- Give Sleep the primary area when selected: total asleep, bedtime and wake time, a stage bar, and Awake/Light/REM/Deep durations.
- Show Steps, Resting Heart Rate, and HRV as compact metric cards. Reflow selected content without leaving gaps; keep the position of a selected metric when its data is missing.
- Include one fixed, static, purely decorative mascot. It may be authored in 3D but must ship as pre-rendered 2D artwork and must not imply health status.
- Show the Last Successful Update in a low-emphasis footer, together with stale, offline, update-failed, or reconnect status when applicable.
- Make the whole Widget open the Companion App's status/settings screen. Do not add an in-Widget refresh button.

## Menu Bar Experience

- Use SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)` on macOS 15+. Use the existing App symbol, `heart.text.square.fill`, as a monochrome template icon with the accessible name `Fitbit Widget`; do not show health values, badges, or animation in the menu bar itself.
- Clicking the icon opens a roughly 340-point-wide vertical popover. Let macOS position and dismiss it when clicking outside; support Escape and native keyboard navigation. Do not create a custom status item, panel, global event monitor, or always-on-top window.
- Show a compact `Health at a glance` header with the Widget's small, static decorative mascot, then only the selected metrics: Sleep first when selected, followed by Steps, Resting Heart Rate and HRV. Keep the stored selection order unchanged. Use simple rows for daily values and a compact Sleep section with total asleep, bedtime/wake time, stage bar and four stage durations. Preserve missing/permission rows and the existing metric/date/stage semantics; keep the vertical composition specific to the Menu Bar.
- Use the Widget's rounded numeric typography, metric/stage colors, quiet surfaces and spacing, with native controls. Fit the usual four-metric layout comfortably; allow scrolling on shorter displays or with accessibility needs. Preserve legibility in light/dark appearance and increased contrast, provide VoiceOver reading order and labeled icon buttons, and hide decorative artwork from accessibility.
- Keep Last Successful Update and stale/offline/update-failed/reconnect status in a low-emphasis footer. Show cached content immediately and retain it during refresh. Without usable cache, show the existing connection/profile/initial-load state with an `Open Settings…` action; never initiate OAuth from the popover.
- Provide `Refresh Now`, a labeled settings icon (`Open Settings…`), and a secondary `Quit Fitbit Widget` action. Settings opens and activates the existing single status/settings window, dismissing the popover; use the same destination for Widget taps and the standard Settings command. Connection, permissions, selection and deletion stay in that window.
- Opening the popover reloads shared state and offers a freshness-gated refresh through the existing App model. Disable duplicate refresh actions while connecting/refreshing, during persisted retry cooldown, when reconnect is required, or when no selected metric is authorized. Partial authorization must still allow refreshing granted metrics. Dismissing the popover does not cancel an App-owned sync.

### Enablement And Lifecycle

`Show in Menu Bar`, whether the App is running, and `Launch at Login` are separate concepts. Persist the Menu Bar preference in App-local preferences with a default of `true` when absent, including upgrades. Bind it to `MenuBarExtra.isInserted` so native removal also persists. Its setter must ignore unchanged values before publishing: macOS writes insertion state back during scene reconciliation, and unconditional `@Published` updates cause an infinite App graph update loop. Keep it outside the health snapshot and preserve it through Sign Out or Delete Local Data.

| Event | Expected behavior |
| --- | --- |
| First manual launch, before connection | Open setup/settings and insert the icon. The popover offers `Connect Google Health in App` / `Open Settings…`; do not open the popover or browser automatically. |
| Successful initial connection | Both surfaces use the committed snapshot and authorized selection. Do not force the popover open or require Widget installation. |
| Normal operation; settings closed or App hidden | Keep the icon and shared App model alive. Closing settings is not Quit. Keep the existing regular Dock icon and activation policy; do not add `LSUIElement` or a hidden-Dock mode. |
| Menu Bar disabled | Remove the icon immediately without quitting, clearing data, changing Widget behavior, or changing Launch at Login. Settings remains reachable from the Dock/App menu. |
| Menu Bar re-enabled | Insert the icon immediately without reconnecting or resetting selection. Reload cache; the next popover opening uses the normal refresh gate. |
| Sign Out / Delete Local Data | Clear local health/connection state for both surfaces; retain Menu Bar and login preferences. If enabled, the icon remains and shows the unconnected state. Remote revocation remains Build #5 work. |
| Quit / manual relaunch | Quit removes the icon and stops App sync; an installed Widget can still refresh independently. Manual launch or Dock reopen shows the same settings window and restores the saved icon preference. |
| Mac restart and next login | The preference alone does not start the App. With Launch at Login off, users must launch it unless macOS session restoration opens it. With login launching approved/enabled, start the App and restore the icon preference; when the Menu Bar is enabled, keep settings closed and do not activate the App or start OAuth. If the Menu Bar is disabled, show the status/settings window rather than leaving no visible surface. |

Include an independent `Launch at Login` option, **off by default**, using `SMAppService.mainApp`; no helper executable, LaunchAgent, or daemon. Explain that the Menu Bar is available only while the App runs. Register/unregister only on explicit user action, show actual system service status (including approval required or registration failure), and recheck when settings becomes active. Never silently re-register after the user disables it in macOS settings. Changing either setting must not silently change the other.

Keep the current `Window(id: "status")`; route explicit settings actions through native `openWindow`, and handle the existing `fitbitwidget://status` URL at App scope so Widget taps open that same window. Keep the small AppKit lifecycle adapter for login-launch detection and Dock reopen handling, with native scene actions for opening/dismissing settings; do not add custom popover management or delayed hide-window workarounds. Validate quiet login launch and explicit window opening on macOS 15 before building the rest of the surface.

Native API references: [MenuBarExtra and insertion binding](https://developer.apple.com/documentation/swiftui/menubarextra), [window style](https://developer.apple.com/documentation/swiftui/menubarextrastyle/window), [main-app login service](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp), and [login launch event](https://developer.apple.com/documentation/coreservices/1556410-launch_apple_event_constants/keyaelaunchedasloginitem).

## Metric Semantics

Use Google Health API v4 with the `google-sources` source family. Display values supplied or reconciled by Google; do not derive health metrics locally.

| Metric | Definition | Valid data window | Display |
| --- | --- | --- | --- |
| Steps | Official daily rollup for the Mac's current local calendar day | Today only | Integer steps |
| Sleep | Most recent reconciled `mainSleep`, attributed to its local wake date; headline is `minutesAsleep`, excluding awake/restless time and naps | Session ended within the last 36 hours | Hours/minutes plus local bedtime and wake time |
| Resting Heart Rate | Google daily resting-heart-rate value; never calculated from ordinary heart-rate samples | Today or the preceding three calendar days | Integer bpm; show the source date when not today |
| HRV | Google daily average HRV value; never recalculated from intraday or sleep samples | Today or the preceding three calendar days | Integer ms labeled `HRV`; show the source date when not today |

For staged Sleep, display Google's Awake, Light, REM, and Deep durations from the reconciled stage summary. For classic sleep or pending/failed stage processing, keep the total asleep when available and mark unavailable stages as `Processing` or `Unavailable`; never infer stages or treat missing data as zero. Prefer civil start/end times and fall back to timestamps plus their UTC offsets.

At local midnight, invalidate the previous day's Steps and show `No Data Today` until a new rollup succeeds. Do not retain a local history database.

**Readiness is excluded.** Google Health API v4 does not expose the Google/Fitbit Readiness score, and the MVP will not invent a recovery score.

## Google Health And OAuth

- Use a Desktop OAuth client, the system browser, Authorization Code flow, loopback redirect, and PKCE. Supply the matching Desktop client secret when Google requires it, through local build configuration excluded from Git. This Desktop application credential is extractable from a distributed app and is not a confidential security boundary; PKCE remains required. Never commit actual credential values.
- Before building the data layer, validate this flow through `users/me/identity`. Use Google Sign-In for macOS only if the native flow proves incompatible.
- Request these read-only scopes together on first connection:
  - Activity and Fitness for Steps.
  - Sleep for Sleep.
  - Health Metrics and Measurements for Resting Heart Rate and HRV.
- Do not request the Settings scope; `Last Successful Update` means the Mac's last successful API refresh, not wearable sync time.
- Support partial authorization. Default-select only granted metrics; keep ungranted metrics disabled in the App with `Permission Required` and a reauthorization action.
- If a previously selected permission is revoked, keep that metric's position on both surfaces and show `Permission Required`; other metrics continue working.
- Treat `ACCOUNT_NOT_LINKED` as a setup prerequisite, not empty data. Explain that the same Google account must first have a Google Health profile configured through a compatible phone; there is no legacy Fitbit API fallback.
- OAuth cancellation returns to the unconnected state without an error.

## Sync, Refresh, And Cache

- The Companion App and Widget Extension share one sync implementation.
- Sync from the App after connection, on launch/activation, after metric-selection changes, and when the user chooses `Refresh Now`. Menu Bar opening uses the same non-forcing `.launch` path: reuse a successful snapshot younger than five minutes with matching selection, except when local-day rollover requires new Steps. Keep the existing 40-second App budget; manual `.manual` refresh forces a fetch only when existing connection/permission, in-flight and backoff gates allow it.
- Let the Widget Extension attempt a short, bounded refresh while the App is closed. Request a new timeline about hourly, while clearly treating WidgetKit scheduling as opportunistic rather than guaranteed.
- Coalesce concurrent refreshes and use bounded exponential backoff for retryable API/rate-limit failures.
- Commit a new normalized snapshot atomically only when every selected and authorized metric request completes successfully. A successful empty result is valid and updates that metric to missing; a transport, server, or parsing failure preserves the entire prior snapshot.
- Update `Last Successful Update` only when committing that complete snapshot.
- After a successful write, request a WidgetKit timeline reload. A reload request does not promise immediate rendering.
- Schedule a local-midnight timeline entry so yesterday's Steps cannot remain labeled as today's.
- Menu Bar-only use has no dependency on WidgetKit execution. Refresh on App launch/activation, popover opening and explicit actions; do not add hourly App polling, a resident sync timer, or guaranteed background freshness. A closed popover may age; the next opening displays cache immediately and checks for an update. An already-open popover reflects completed syncs but does not continuously fetch.

### Build #4.5 Integration Boundary

- Reuse `SharedWidgetState`, `HealthSnapshot`, `MetricSelection`, permissions, `SyncMetadata`, `SharedWidgetStore`, shared Keychain and `HealthSync` unchanged in purpose. Keep the existing snapshot envelope/version and atomic commit/failure rules. Do not add another API client, OAuth flow, data store, snapshot format, or sync engine.
- Move `CompanionAppModel` ownership from `CompanionAppView` to the App root and inject the same instance into settings and the Menu Bar. Both share one `HealthSync` instance, activity and task lifetime. Remove duplicate view-owned launch/activation triggers; closing a window must not destroy the model or launch another coordinator. Retain per-process coalescing, cross-process `flock` leases, token/connection/selection guards, retry/backoff and Widget timeline reloads.
- `WidgetCenter.reloadTimelines` does not update App memory. Use one App-owned `DispatchSource` filesystem observer on the App Group **containing directory**, because atomic snapshot replacement changes the file inode. Coalesce events, reload `SharedWidgetStore` on MainActor, and publish only changed state; handle snapshot creation/replacement/deletion and cancel/close the observer on termination. Never treat an event as a reason to call the API or pass health values through notifications. See [Apple's filesystem event source](https://developer.apple.com/documentation/dispatch/dispatchsource).
- Register observation before the initial read. Also reload on launch, popover opening, settings activation, wake and after sync completion so missed/coalesced events and cross-process lease contention cannot leave the display stuck. An Extension commit, permission/error write or reset must update an open popover without reopening it. The snapshot remains authoritative; do not write view state back during reload.
- Apply current permissions and `HealthSnapshot.resolved(at:calendar:)` at display time; honor `SyncMetadata.reconnectRequired` even before the first snapshot exists. Reuse `transitionDates` for a single reschedulable local reevaluation while the popover is visible (midnight, six-hour staleness, Sleep/daily-value expiry); reevaluate after wake or clock/time-zone change. Include retry-cooldown expiry when either the popover or settings is active so refresh controls recover without reopening. Cancel when neither surface is active. This changes presentation only, never triggers network work. Both surfaces use the shared minute-precision update-age label (Updated now / Updated 1 minute ago / Updated N minutes ago), with a locale-aware timestamp in help and no seconds. Use native TimeDataSource text with SystemFormatStyle.DateReference restricted to minutes; no extra timeline entries, presentation timers, or API calls are needed.
- Share small formatting/status helpers (duration, civil time/offset, units, source date, missing/permission and freshness/error wording), colors and the static mascot where practical. Extract leaf visuals such as a stage bar only when both layouts benefit. Keep `FitbitWidgetEntryView`, timeline/provider, Widget background/rendering modifiers, footer navigation and fixed-card layout Widget-specific. Compose Menu Bar rows separately; do not compile the entire Widget view into the App or create a generic UI framework.

## Storage And Security

- Store OAuth tokens only in a shared, non-synchronizable Data Protection Keychain access group available to the App and Widget Extension.
- Store only global metric selection, minimal permission metadata, freshness state, and the normalized current health snapshot for both surfaces in the App Group. Rely on App Sandbox, App Group access controls, and Apple Silicon Data Protection for encryption at rest. Write the snapshot atomically and exclude it from backups. Menu Bar enablement is an App-local preference; Launch at Login state comes from Service Management.
- Never store tokens, raw API responses, or health-data history in the App Group.
- Do not send health data to an app backend. The MVP has no account backend, analytics, advertising, or third-party crash-reporting SDK.
- Never log tokens, complete API responses, or health values. Use only Apple/TestFlight diagnostics that testers elect to share.
- Sign Out first attempts Google token revocation, then always removes local tokens, snapshots, permission/freshness state, and metric selection. If remote revocation fails offline, provide instructions for removing access from the Google Account.

## Freshness, Missing Data, And Errors

- Mark the snapshot stale when Last Successful Update is more than six hours old. Keep cached data visible with its age until Sign Out, subject to each metric's valid data window.
- Treat a reported numeric zero as data. Treat no datapoint in the valid window as `—` / `No Recent Data`.
- Never replace a usable snapshot with a failed or partial sync.
- With cache:
  - Network failure: keep values and show `Offline · Updated … ago`.
  - Other sync failure: keep values and show `Update Failed · Updated … ago`.
  - Expired authorization: keep still-valid values and show `Reconnect in App`.
- Without cache:
  - Unconnected: show `Connect Google Health in App`.
  - Connected but initial sync failed: show `Unable to Load Data · Open App`.
- Apply these states to the Widget and Menu Bar equally. Keep HTTP, OAuth, and parsing details in the Companion App settings, not either health surface.

## Companion App

The App is a setup and recovery utility and the host for the optional Menu Bar, not a health dashboard. The health popover does not turn the settings window into a second dashboard.

First-run flow:

1. Show a clear health-data disclosure covering requested data, purpose, local encrypted storage, no sharing, and deletion through Sign Out.
2. Connect through system-browser OAuth.
3. Verify the Google Health identity/profile.
4. Complete the first full sync.
5. Default-select all authorized metrics and allow adjustment.
6. Explain that the Menu Bar is already available, how to add the optional Widget from the macOS Widget Gallery, and the optional Launch at Login setting. Do not add another required setup step.

After setup, use one compact status/settings screen containing the connected account, per-scope permission status, Last Successful Update and sync error, metric selection, `Refresh Now`, `Show in Menu Bar`, `Launch at Login`, Widget installation help, privacy links, and a specific `Sign Out` action. Group the two behavior toggles in a small section; keep optional Widget help secondary and connection/recovery prominent. Describe metric selection as applying to both surfaces. Do not add history charts, a duplicate health dashboard, or a Sleep detail page.

## Private Beta Requirements

- Accept Google OAuth Testing constraints for the MVP: no more than 100 explicitly listed Google test users, possible unverified-app warnings, and approximately weekly reauthorization.
- TestFlight and Google OAuth access are separate; each tester must be admitted to both and use the approved Google account.
- Publish accessible Privacy Policy and Terms URLs before external testing. The policy and in-app disclosure must describe data categories, purpose, local storage/security, deletion, and no sharing.
- Treat Google verification and any required CASA security assessment as blockers for a broader public release, not as permission to launch publicly under the testing cap.
- Validate shared Keychain access, App Group access controls and platform Data Protection, extension token refresh, OAuth recovery, and real WidgetKit cadence in a TestFlight build outside the debugger.

## Not In MVP

- Small, Medium, or Extra Large Widget families.
- Per-Widget configuration, metric drag ordering, multiple Google accounts, or mascot selection.
- Data-driven character states, live 3D, Three.js/WebGL, continuous animation, or a proprietary readiness/recovery score.
- Historical analytics, charts, full health dashboard, AI coaching, or medical advice.
- Separate Menu Bar metric settings, live menu-bar values, global shortcuts, detachable/pinned popovers, hidden-Dock modes, custom window management, or an additional background sync service.
- iPhone, Intel Mac, Windows, Android, Apple Health, subscriptions, social features, or always-on-top windows.
- Public App Store launch.

## Build Order

| Build | Deliverable |
| --- | --- |
| #1 | Build the Large Widget with mock data and all empty/stale/error states; validate it on the actual Mac desktop in light, dark, and macOS widget rendering modes. |
| #2 | Build the minimal Companion App, shared selection, platform-protected App Group snapshot, and shared Keychain boundary. |
| #3 | Complete the OAuth/identity spike, then implement Google Health scopes, partial authorization, account-link checks, and the four metric mappings. |
| #4 — Complete | Add shared App/Extension sync, atomic cache commits, WidgetKit timelines, midnight rollover, retry, and recovery behavior. |
| **#4.5 — Menu Bar Experience** | Native icon/popover, shared App model and snapshot observation, default-enabled setting, opt-in Launch at Login, settings routing and existing refresh/recovery behavior are implemented; native interaction and signed login validation remain pending. |
| #5 | Validate privacy copy, Sign Out/revocation, accessibility, TestFlight entitlements, and real-device refresh behavior for Widget-only, Menu Bar-only and combined use before inviting external testers. |

### Build #4.5 Implementation Sequence

1. Validate `MenuBarExtra(.window)`, insertion persistence, settings/Dock reopening and quiet login launching on macOS 15 with the existing regular App. Add the two settings and Service Management status handling; keep the existing minimum OS and Dock behavior.
2. Lift the existing App model to App scope, wire both scenes to it, and consolidate activation/open/manual refresh entry points with the existing freshness and concurrency gates.
3. Add directory observation, authoritative reloads and visible-only time-boundary reevaluation. Verify Extension writes, atomic replacement, deletion and wake while the popover is open.
4. Extract only the small shared presentation helpers/leaf visuals needed, then compose the vertical popover and all connection/metric/status states without changing the Widget layout.
5. Use mock sessions and temporary stores to verify shared selection, no-Widget operation, concurrent refresh/cooldown, failures, expiry/midnight, disconnect and settings lifecycle. Build/test both targets and manually check outside-click/Escape dismissal, keyboard/VoiceOver, appearance, toggle/relaunch/login behavior and idle resource use. Do not consume live Google quota for UI checks or start Build #5 release work.

Implementation validation: App and Extension compile with the macOS 15 deployment target; 86 mock/local-store tests pass on macOS 26. An isolated native startup test reproduced and fixed the insertion-writeback loop (1,776 scene evaluations in six seconds before the fix, one afterward; the main thread returns to normal event waiting). Actual popover interaction, light/dark appearance, keyboard/VoiceOver, sustained idle resource use and signed macOS 15/login-item behavior still require on-device checks. Do not treat unit-tested lifecycle routing as proof of a real login launch.

## MVP Done When

- An approved tester can install through TestFlight, connect an eligible Google Health account without developer setup, complete the first sync, and use the Menu Bar, the Widget, or both.
- The Large Widget clearly shows the selected available metrics with the specified semantics and updates without manually opening the App under normal conditions.
- Missing, stale, offline, partial-permission, expired-auth, and unlinked-account states are distinct and actionable.
- Cached values remain readable offline without being presented as current.
- Tokens and health data stay encrypted and local, Sign Out clears them, and no user token or confidential server credential is shipped in the app.
- The Widget is polished and accessible across supported macOS appearances.
- The default-enabled Menu Bar works without an installed Widget, shows the same selection/permissions/cache/error semantics, and updates while open when either process writes shared state. No duplicate request pipeline is introduced.
- Users can disable/re-enable the Menu Bar without losing data or affecting the Widget, open settings and refresh from the popover, and close settings while keeping the icon available.
- Launch at Login is optional and reflects macOS approval/status; icon enablement alone never promises presence after restart. Quit and login behavior are clear, native and validated on macOS 15+.
- The popover is polished, keyboard/VoiceOver accessible, readable in light/dark appearance, and uses no recurring background polling while idle.

## Private Beta Naming Decision

Use `Fitbit Widget` as the working product name for the private TestFlight beta. This is an independent third-party product and must not use Google or Fitbit logos, trade dress, or language that implies endorsement. User-facing connection actions must refer to `Google Health`, because that is the service the app connects to. Revisit the product name before any broader public release or formal Google verification.
