# Fitbit Mac Widget

## MVP Goal

Build a polished, lightweight native macOS desktop widget that shows selected Google Health metrics without requiring the user to open a dashboard.

**Ideal flow:** Install the Mac app through TestFlight → connect Google Health → review permissions and metric selection → add the Widget from the macOS Widget Gallery.

## Product Boundary

- **Platform:** Apple Silicon Mac running macOS 14 or later.
- **Distribution:** Small external TestFlight beta; not a public App Store launch.
- **Widget:** One Large WidgetKit card for the desktop or Notification Center; never always-on-top.
- **Account:** One connected Google account at a time.
- **Language:** English UI. Dates, times, number formatting, and 12/24-hour time follow macOS locale settings.
- **Design:** Calm, information-dense, accessible, and legible in light, dark, and macOS widget rendering modes.

## Widget Experience

- Default to all four authorized metrics: Steps, Sleep, Resting Heart Rate, and HRV.
- Let the user select 1–4 metrics in the Companion App. Use the fixed order above; do not support drag ordering or per-Widget configuration.
- All Widget instances share one selection.
- Give Sleep the primary area when selected: total asleep, bedtime and wake time, a stage bar, and Awake/Light/REM/Deep durations.
- Show Steps, Resting Heart Rate, and HRV as compact metric cards. Reflow selected content without leaving gaps; keep the position of a selected metric when its data is missing.
- Include one fixed, static, purely decorative mascot. It may be authored in 3D but must ship as pre-rendered 2D artwork and must not imply health status.
- Show the Last Successful Update in a low-emphasis footer, together with stale, offline, update-failed, or reconnect status when applicable.
- Make the whole Widget open the Companion App's status/settings screen. Do not add an in-Widget refresh button.

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

- Use a Desktop OAuth client, the system browser, Authorization Code flow, loopback redirect, and PKCE. Never embed a client secret.
- Before building the data layer, validate this flow through `users/me/identity`. Use Google Sign-In for macOS only if the native flow proves incompatible.
- Request these read-only scopes together on first connection:
  - Activity and Fitness for Steps.
  - Sleep for Sleep.
  - Health Metrics and Measurements for Resting Heart Rate and HRV.
- Do not request the Settings scope; `Last Successful Update` means the Mac's last successful API refresh, not wearable sync time.
- Support partial authorization. Default-select only granted metrics; keep ungranted metrics disabled in the App with `Permission Required` and a reauthorization action.
- If a previously selected permission is revoked, keep that metric's Widget position and show `Permission Required`; other metrics continue working.
- Treat `ACCOUNT_NOT_LINKED` as a setup prerequisite, not empty data. Explain that the same Google account must first have a Google Health profile configured through a compatible phone; there is no legacy Fitbit API fallback.
- OAuth cancellation returns to the unconnected state without an error.

## Sync, Refresh, And Cache

- The Companion App and Widget Extension share one sync implementation.
- Sync from the App after connection, on launch, after metric-selection changes, and when the user chooses `Refresh Now`.
- Let the Widget Extension attempt a short, bounded refresh while the App is closed. Request a new timeline about hourly, while clearly treating WidgetKit scheduling as opportunistic rather than guaranteed.
- Coalesce concurrent refreshes and use bounded exponential backoff for retryable API/rate-limit failures.
- Commit a new normalized snapshot atomically only when every selected and authorized metric request completes successfully. A successful empty result is valid and updates that metric to missing; a transport, server, or parsing failure preserves the entire prior snapshot.
- Update `Last Successful Update` only when committing that complete snapshot.
- After a successful write, request a WidgetKit timeline reload. A reload request does not promise immediate rendering.
- Schedule a local-midnight timeline entry so yesterday's Steps cannot remain labeled as today's.

## Storage And Security

- Store OAuth tokens only in a shared, non-synchronizable Data Protection Keychain access group available to the App and Widget Extension.
- Store only global metric selection, minimal permission metadata, freshness state, and the normalized current Widget snapshot in the App Group. Rely on App Sandbox, App Group access controls, and Apple Silicon Data Protection for encryption at rest. Write the snapshot atomically and exclude it from backups.
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
- Keep HTTP, OAuth, and parsing details in the Companion App, not the Widget.

## Companion App

The App is a setup and recovery utility, not a health dashboard.

First-run flow:

1. Show a clear health-data disclosure covering requested data, purpose, local encrypted storage, no sharing, and deletion through Sign Out.
2. Connect through system-browser OAuth.
3. Verify the Google Health identity/profile.
4. Complete the first full sync.
5. Default-select all authorized metrics and allow adjustment.
6. Explain how to add the Widget from the macOS Widget Gallery.

After setup, use one compact status/settings screen containing the connected account, per-scope permission status, Last Successful Update and sync error, metric selection, `Refresh Now`, Widget installation help, privacy links, and a specific `Sign Out` action. Do not add history charts, a duplicate health dashboard, or a Sleep detail page.

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
- iPhone, Intel Mac, Windows, Android, Apple Health, subscriptions, social features, or always-on-top windows.
- Public App Store launch.

## Build Order

1. Build the Large Widget with mock data and all empty/stale/error states; validate it on the actual Mac desktop in light, dark, and macOS widget rendering modes.
2. Build the minimal Companion App, shared selection, platform-protected App Group snapshot, and shared Keychain boundary.
3. Complete the OAuth/identity spike, then implement Google Health scopes, partial authorization, account-link checks, and the four metric mappings.
4. Add shared App/Extension sync, atomic cache commits, WidgetKit timelines, midnight rollover, retry, and recovery behavior.
5. Validate privacy copy, Sign Out/revocation, accessibility, TestFlight entitlements, and real-device refresh behavior before inviting external testers.

## MVP Done When

- An approved tester can install through TestFlight, connect an eligible Google Health account without developer setup, complete the first sync, and add the Widget.
- The Large Widget clearly shows the selected available metrics with the specified semantics and updates without manually opening the App under normal conditions.
- Missing, stale, offline, partial-permission, expired-auth, and unlinked-account states are distinct and actionable.
- Cached values remain readable offline without being presented as current.
- Tokens and health data stay encrypted and local, Sign Out clears them, and no secret is shipped in the app.
- The Widget is polished and accessible across supported macOS appearances.
