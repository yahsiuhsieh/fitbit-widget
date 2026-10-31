import AppKit
import SwiftUI
import WidgetKit

struct SharedTimelineProvider: TimelineProvider {
    private let store: SharedWidgetStore?

    init(store: SharedWidgetStore? = SharedWidgetStore()) {
        self.store = store
    }

    func placeholder(in context: Context) -> FitbitWidgetEntry {
        .normal
    }

    func getSnapshot(in context: Context, completion: @escaping (FitbitWidgetEntry) -> Void) {
        guard !context.isPreview else {
            completion(.normal)
            return
        }

        completion(FitbitWidgetEntry(date: Date(), state: store?.load() ?? .initial))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FitbitWidgetEntry>) -> Void) {
        if context.isPreview {
            completion(Timeline(entries: [.normal], policy: .never))
            return
        }
        let completion = TimelineCompletion(completion)
        Task { @MainActor in
            let result = await HealthSync.shared.refresh(.widget)
            let now = Date()
            let schedule = WidgetTimelineSchedule.make(
                state: store?.load() ?? result.state,
                startingAt: now,
                calendar: SharedConfiguration.localCalendar
            )
            let entries = schedule.items.map { FitbitWidgetEntry(date: $0.date, state: $0.state) }
            let canRetrySoon = result.state.sync.nextAttempt == nil && !result.state.sync.reconnectRequired
            let refresh = canRetrySoon && (result.coalesced || result.failure != nil)
                ? min(schedule.refreshDate, now.addingTimeInterval(300)) : schedule.refreshDate
            completion.call(Timeline(entries: entries, policy: .after(refresh)))
        }
    }
}

// WidgetKit's completion is invoked once on MainActor after the bounded refresh.
private final class TimelineCompletion: @unchecked Sendable {
    let call: (Timeline<FitbitWidgetEntry>) -> Void
    init(_ call: @escaping (Timeline<FitbitWidgetEntry>) -> Void) { self.call = call }
}

struct FitbitHealthWidget: Widget {
    static let kind = SharedConfiguration.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SharedTimelineProvider()) { entry in
            FitbitWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Fitbit Widget")
        .description("Steps, sleep, resting heart rate, and HRV at a glance.")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

struct FitbitWidgetEntryView: View {
    let entry: FitbitWidgetEntry

    var body: some View {
        Group {
            switch entry.state.content {
            case let .data(data):
                populatedContent(data)
            case .unconnected, .accountNotLinked, .initialSyncFailed:
                InitialWidgetView(content: entry.state.content)
            }
        }
        .padding(18)
        .containerBackground(for: .widget) {
            WidgetBackground()
        }
        .widgetURL(URL(string: "fitbitwidget://status"))
    }

    private func populatedContent(_ data: WidgetData) -> some View {
        let permitted = entry.state.hasVerifiedIdentity
            ? data.snapshot.applyingPermissions(entry.state.permissions) : data.snapshot
        let snapshot = permitted.resolved(at: entry.date, calendar: SharedConfiguration.localCalendar)

        return VStack(alignment: .leading, spacing: 10) {
            header

            WidgetMetricLayout(
                selectedMetrics: entry.state.selection.metrics,
                snapshot: snapshot,
                evaluationDate: entry.date
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            WidgetFooter(
                issue: data.lastSyncIssue,
                isStale: snapshot.isStale,
                lastSuccessfulUpdate: snapshot.lastSuccessfulUpdate
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Health at a glance")
                    .font(.system(.headline, design: .rounded, weight: .semibold))

                Text(entry.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("Google Health")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)

                MascotMark(size: 34)
            }
        }
    }
}

private struct WidgetMetricLayout: View {
    let selectedMetrics: [MetricKind]
    let snapshot: ResolvedHealthSnapshot
    let evaluationDate: Date

    private var showsSleep: Bool {
        selectedMetrics.contains(.sleep)
    }

    private var compactMetrics: [MetricKind] {
        selectedMetrics.filter { $0 != .sleep }
    }

    var body: some View {
        VStack(spacing: 10) {
            if showsSleep {
                SleepCard(state: snapshot.sleep)
                    .frame(maxWidth: .infinity)
            }

            if !compactMetrics.isEmpty {
                CompactMetricRow(
                    metrics: compactMetrics,
                    snapshot: snapshot,
                    evaluationDate: evaluationDate,
                    emphasizesMetrics: !showsSleep
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct SleepCard: View {
    let state: MetricState<SleepSession>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sleep", systemImage: MetricKind.sleep.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            switch state {
            case let .value(session):
                sessionContent(session)
            case .noData:
                MissingReadingView(message: "No Recent Data")
                    .frame(maxHeight: .infinity)
            case .permissionRequired:
                MissingReadingView(message: "Permission Required")
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
        .accessibilityElement(children: .contain)
    }

    private func sessionContent(_ session: SleepSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(durationText(session.minutesAsleep))
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    Text(timeText(session.start))
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                    Text(timeText(session.end))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            SleepStageContent(state: session.stages)
        }
    }
}

private struct CompactMetricRow: View {
    let metrics: [MetricKind]
    let snapshot: ResolvedHealthSnapshot
    let evaluationDate: Date
    let emphasizesMetrics: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(metrics) { metric in
                CompactMetricCard(
                    metric: metric,
                    state: state(for: metric),
                    evaluationDate: evaluationDate,
                    emphasizesValue: emphasizesMetrics
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func state(for metric: MetricKind) -> MetricState<DailyMetricValue> {
        switch metric {
        case .steps: snapshot.steps
        case .restingHeartRate: snapshot.restingHeartRate
        case .hrv: snapshot.hrv
        case .sleep: .noData
        }
    }
}

private struct CompactMetricCard: View {
    let metric: MetricKind
    let state: MetricState<DailyMetricValue>
    let evaluationDate: Date
    let emphasizesValue: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: metric.symbolName)
                    .foregroundStyle(metric.tint)
                Text(metric == .restingHeartRate ? "Resting HR" : metric.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .accessibilityLabel(metric.title)
            }

            Spacer(minLength: 2)

            readingContent

            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var readingContent: some View {
        switch state {
        case let .value(value):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value.value.formatted(.number.grouping(.automatic)))
                    .font(
                        .system(
                            size: emphasizesValue ? 27 : 23,
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .monospacedDigit()

                Text(unit)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.65)

            if let sourceDateText = sourceDateText(value) {
                Text(sourceDateText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text("Source date")
                    .font(.caption2)
                    .hidden()
                    .accessibilityHidden(true)
            }

        case .noData:
            MissingReadingView(message: metric == .steps ? "No Data Today" : "No Recent Data")

        case .permissionRequired:
            MissingReadingView(message: "Permission Required")
        }
    }

    private var unit: String { metric.unit }

    private func sourceDateText(_ value: DailyMetricValue) -> String? {
        metricSourceDateText(value, metric: metric, evaluationDate: evaluationDate)
    }

}

private struct MissingReadingView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("—")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct WidgetFooter: View {
    let issue: SyncIssue?
    let isStale: Bool
    let lastSuccessfulUpdate: Date

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)

            ForEach(statusTitles, id: \.self) { title in
                Text(title)
                    .fontWeight(.semibold)

                Text("·")
            }

            UpdatedAgeText(lastSuccessfulUpdate: lastSuccessfulUpdate)

            Spacer()

            Text("Open app")
            Image(systemName: "arrow.up.forward.app")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .combine)
    }

    private var statusTitles: [String] {
        freshnessTitles(issue: issue, isStale: isStale)
    }

    private var symbolName: String {
        if let issue { return issue.symbolName }
        return isStale ? "clock.badge.exclamationmark.fill" : "checkmark.circle.fill"
    }

    private var tint: Color {
        if let issue { return issue.tint }
        return isStale ? .orange : .green
    }

}

private struct InitialWidgetView: View {
    let content: WidgetContent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square.fill")
                    .foregroundStyle(.tint)

                Text("Fitbit Widget")
                    .fontWeight(.semibold)

                Spacer()

                MascotMark(size: 44)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Spacer(minLength: 18)

            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.accentColor.opacity(0.1))

                    Image(systemName: statusSymbolName)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.tint)
                }
                .frame(width: 62, height: 62)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 9) {
                    Text(title)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("Open App", systemImage: "arrow.up.forward.app")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.top, 3)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            }

            Spacer(minLength: 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch content {
        case .unconnected: "Connect Google Health"
        case .accountNotLinked: "Google Health Profile Required"
        case .initialSyncFailed: "Unable to Load Data"
        case .data: "Open the App to Get Started"
        }
    }

    private var subtitle: String {
        switch content {
        case .unconnected:
            "Open the app to connect your account and prepare the Widget."
        case .accountNotLinked:
            "Set up Google Health on a compatible phone, then return to the app."
        case .initialSyncFailed:
            "Open the app to try loading your health data again."
        case .data:
            "Open the app to prepare the Widget."
        }
    }

    private var statusSymbolName: String {
        switch content {
        case .unconnected: "link.badge.plus"
        case .accountNotLinked: "person.crop.circle.badge.exclamationmark"
        case .initialSyncFailed: "arrow.clockwise.circle"
        case .data: "heart.text.square.fill"
        }
    }
}

private struct WidgetBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.08),
                    Color.clear,
                    Color.indigo.opacity(0.035)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

struct FitbitWidgetEntryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            preview(.normal, name: "1 · Normal")
            preview(.missingMetric, name: "2 · Missing Metric")
            preview(.stale, name: "3 · Stale")
            preview(.offline, name: "4 · Offline Cache")
            preview(.offlineAndStale, name: "5 · Offline + Stale")
            preview(.updateFailed, name: "6 · Update Failed")
            preview(.reconnectRequired, name: "7 · Reconnect Required")
            preview(.unconnected, name: "8 · Unconnected")
            preview(.accountNotLinked, name: "9 · Account Not Linked")
            preview(.initialSyncFailed, name: "10 · Initial Sync Failed")
            preview(.permissionRequired, name: "Permission Required")
            preview(.sleepPermissionRequired, name: "Sleep · Permission Required")
            preview(.missingSleep, name: "Sleep · Missing")
            preview(.sleepStagesProcessing, name: "Sleep · Stages Processing")
            preview(.sleepStagesUnavailable, name: "Sleep · Stages Unavailable")
            preview(.zeroSteps, name: "Steps · Zero")
            preview(.worstCase, name: "Worst Case Values")
            preview(.sleepAndSteps, name: "Reflow · Sleep + Steps")
            preview(.compactOnly, name: "Reflow · No Sleep")
            preview(.sleepOnly, name: "Reflow · Sleep Only")
        }
    }

    private static func preview(_ entry: FitbitWidgetEntry, name: String) -> some View {
        FitbitWidgetEntryView(entry: entry)
            .previewContext(WidgetPreviewContext(family: .systemLarge))
            .previewDisplayName(name)
    }
}
