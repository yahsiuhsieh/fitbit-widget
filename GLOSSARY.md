# Fitbit Mac Widget

Canonical product language for the macOS widget and its companion app.

## Language

**Widget**:
The single Large desktop card that gives a glanceable view of the user's selected Google Health metrics. Every placement uses the same shared selection.
_Avoid_: Dashboard, always-on-top window

**Widget Instance**:
One placement of the Widget on a Mac desktop. Multiple instances may exist, but they do not have independent settings.
_Avoid_: Custom widget, widget profile

**Companion App**:
The minimal macOS app through which a user connects Google Health and manages the shared Widget settings.
_Avoid_: Dashboard

**Private Beta**:
The MVP distribution stage delivered through TestFlight to a small, explicitly approved group using Apple Silicon Macs and Google OAuth test accounts. It is not a public App Store release.
_Avoid_: Public launch, production release

**Google Health Data**:
Health information returned from Google Health first-party sources, including eligible Google and Fitbit sources. It is not limited to readings produced directly by a wearable.
_Avoid_: Tracker data, device-only data

**Partial Authorization**:
A connected state in which the user granted at least one, but not all, requested Google Health read permissions. Metrics covered by granted permissions remain usable.
_Avoid_: Login failure

**Connected Account**:
The single Google account whose authorization is valid and whose Google Health profile has been confirmed. OAuth success alone does not establish this state.
_Avoid_: Signed-in account, Fitbit account

**Unlinked Account**:
A Google account that completed OAuth but has no usable Google Health profile. It is not a Connected Account and cannot supply Widget data.
_Avoid_: Empty account, sync failure

**Selected Metric**:
One of up to four Google Health measurements the user chooses for every Widget Instance. Selected Metrics use the fixed order Steps, Sleep, Resting Heart Rate, then HRV.
_Avoid_: Per-widget metric, reordered metric

**Last Successful Update**:
The time the Mac last completed every required request and committed a complete usable Widget snapshot. It does not represent the last time a wearable synchronized with a phone.
_Avoid_: Device sync time, live status

**Stale Snapshot**:
A cached Widget snapshot whose Last Successful Update is more than six hours old. It may still be displayed with a warning, but it is not presented as current.
_Avoid_: Missing data, expired data

**Missing Data**:
The absence of a usable datapoint within a metric's allowed time window after a successful sync. It is unknown, not zero, and does not mean the snapshot is stale.
_Avoid_: Zero, sync failure, stale data

**Steps**:
The Google Health first-party step total for the current local calendar day. It is not a rolling 24-hour or wearable-only total.
_Avoid_: Daily steps, tracker steps

**Sleep**:
The time actually asleep during the most recent Google-designated main sleep session, attributed to its local wake date. It excludes naps and awake or restless time from the headline duration.
_Avoid_: Time in bed, last night's sleep

**Sleep Stage**:
An Awake, Light, REM, or Deep duration supplied by Google for staged sleep. An unavailable or still-processing stage is unknown, not zero, and is never inferred.
_Avoid_: Estimated stage, zero-length missing stage

**Resting Heart Rate**:
Google Health's daily resting heart-rate value, expressed in beats per minute. It is not calculated from ordinary heart-rate samples by this product.
_Avoid_: Average heart rate, RHR calculation

**HRV**:
Google Health's daily average heart-rate variability value, expressed in milliseconds. It is displayed as provided and is not recalculated by this product.
_Avoid_: Deep-sleep HRV, calculated HRV

**Readiness**:
Google/Fitbit's own recovery score derived from recent physiological data. Google Health API does not expose it, so it is neither displayed nor recreated in the MVP.
_Avoid_: Calculated readiness, recovery estimate

**Mascot**:
The single fixed, static character used as decorative product identity. It never interprets or communicates the user's health state.
_Avoid_: Coach, readiness character, health status

**Sign Out**:
Disconnecting Google Health, attempting to revoke its Google grant, and removing all locally stored authorization, health data, freshness metadata, and metric selections. Local removal succeeds even when remote revocation cannot.
_Avoid_: Log out while keeping data, disconnect only

**Reconnect Required**:
A connected account state whose authorization can no longer refresh Google Health data. Valid cached metrics remain visible until their normal time windows expire or the user signs out.
_Avoid_: Signed out, missing data, offline
