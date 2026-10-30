import AppKit
import SwiftUI
import WidgetKit

struct MockTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> FitbitWidgetEntry {
        .normal
    }

    func getSnapshot(in context: Context, completion: @escaping (FitbitWidgetEntry) -> Void) {
        completion(.normal)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FitbitWidgetEntry>) -> Void) {
        completion(Timeline(entries: [.normal], policy: .never))
    }
}

struct FitbitHealthWidget: Widget {
    static let kind = "FitbitHealthWidgetLarge"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: MockTimelineProvider()) { entry in
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
            if entry.isInitial {
                InitialWidgetView(message: entry.initialMessage ?? "Open the App to Get Started")
            } else {
                populatedContent
            }
        }
        .padding(18)
        .containerBackground(for: .widget) {
            WidgetBackground()
        }
        .widgetURL(URL(string: "fitbitwidget://status"))
    }

    private var populatedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            WidgetMetricLayout(entry: entry)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            WidgetFooter(
                status: entry.syncStatus,
                lastSuccessfulUpdate: entry.lastSuccessfulUpdate
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
    let entry: FitbitWidgetEntry

    private var showsSleep: Bool {
        entry.selectedMetrics.contains(.sleep)
    }

    private var compactMetrics: [MetricKind] {
        entry.selectedMetrics.filter { $0 != .sleep }
    }

    var body: some View {
        VStack(spacing: 10) {
            if showsSleep {
                SleepCard(snapshot: entry.sleep)
                    .frame(maxWidth: .infinity)
            }

            if !compactMetrics.isEmpty {
                CompactMetricRow(
                    metrics: compactMetrics,
                    entry: entry,
                    emphasizesMetrics: !showsSleep
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct SleepCard: View {
    let snapshot: SleepSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sleep", systemImage: MetricKind.sleep.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if let snapshot {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(durationText(snapshot.totalAsleepMinutes))
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.78)

                    Spacer(minLength: 4)

                    HStack(spacing: 6) {
                        Text(snapshot.bedtime, style: .time)
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                        Text(snapshot.wakeTime, style: .time)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }

                SleepStageContent(snapshot: snapshot)
            } else {
                MissingReadingView(message: "No Recent Data")
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

    private func durationText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours) hr \(remainingMinutes) min"
    }
}

private struct SleepStageContent: View {
    let snapshot: SleepSnapshot

    var body: some View {
        switch snapshot.stageStatus {
        case .available:
            VStack(alignment: .leading, spacing: 8) {
                SleepStageBar(stages: snapshot.stages)

                HStack(spacing: 8) {
                    ForEach(snapshot.stages) { stage in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(stage.kind.tint)
                                    .frame(width: 7, height: 7)
                                Text(stage.kind.title)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }

                            Text(stageDuration(stage.minutes))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .processing:
            stageUnavailableLabel("Sleep stages are processing", symbol: "clock")

        case .unavailable:
            stageUnavailableLabel("Sleep stages unavailable", symbol: "minus.circle")
        }
    }

    private func stageDuration(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }

    private func stageUnavailableLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SleepStageBar: View {
    let stages: [SleepStage]

    private var totalMinutes: Int {
        max(stages.reduce(0) { $0 + $1.minutes }, 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let spacing = CGFloat(max(stages.count - 1, 0)) * 4
            let availableWidth = max(proxy.size.width - spacing, 0)

            HStack(spacing: 4) {
                ForEach(stages) { stage in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(stage.kind.tint)
                        .frame(
                            width: max(
                                6,
                                availableWidth * CGFloat(stage.minutes) / CGFloat(totalMinutes)
                            )
                        )
                }
            }
        }
        .frame(height: 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep stage distribution")
    }
}

private struct CompactMetricRow: View {
    let metrics: [MetricKind]
    let entry: FitbitWidgetEntry
    let emphasizesMetrics: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(metrics) { metric in
                CompactMetricCard(
                    metric: metric,
                    reading: entry.reading(for: metric),
                    emphasizesValue: emphasizesMetrics
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CompactMetricCard: View {
    let metric: MetricKind
    let reading: MetricReading?
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
        if let reading {
            switch reading.status {
            case .available:
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(reading.value ?? "—")
                        .font(
                            .system(
                                size: emphasizesValue ? 27 : 23,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .monospacedDigit()
                        .minimumScaleFactor(0.75)

                    Text(reading.unit)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if emphasizesValue {
                    Text(reading.detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

            case let .missing(message):
                MissingReadingView(message: message)

            case .permissionRequired:
                MissingReadingView(message: "Permission Required")
            }
        } else {
            MissingReadingView(message: "No Recent Data")
        }
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

private struct MascotMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.72),
                            Color.accentColor.opacity(0.38)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: size * 0.09) {
                HStack(spacing: size * 0.24) {
                    Circle().frame(width: size * 0.08, height: size * 0.08)
                    Circle().frame(width: size * 0.08, height: size * 0.08)
                }
                .foregroundStyle(.primary.opacity(0.75))

                MascotSmile()
                    .stroke(
                        Color.primary.opacity(0.7),
                        style: StrokeStyle(lineWidth: max(size * 0.04, 1.5), lineCap: .round)
                    )
                    .frame(width: size * 0.38, height: size * 0.15)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.accentColor.opacity(0.15), radius: size * 0.16, y: size * 0.06)
        .accessibilityHidden(true)
    }
}

private struct MascotSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.maxY)
        )
        return path
    }
}

private struct WidgetFooter: View {
    let status: WidgetSyncStatus
    let lastSuccessfulUpdate: Date?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: status.symbolName)
                .foregroundStyle(status.tint)

            if let title = status.title {
                Text(title)
                    .fontWeight(.semibold)

                Text("·")
            }

            if let lastSuccessfulUpdate {
                Text("Updated")
                Text(lastSuccessfulUpdate, style: .relative)
                    .monospacedDigit()
            }

            Spacer()

            Text("Open app")
            Image(systemName: "arrow.up.forward.app")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }
}

private struct InitialWidgetView: View {
    let message: String

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.accentColor.opacity(0.1))

                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.tint)
            }
            .frame(width: 88, height: 88)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .font(.system(.title, design: .rounded, weight: .semibold))

                Text("Open the companion app to connect your account and prepare the widget.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label("Open Fitbit Widget", systemImage: "arrow.up.forward.app")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.top, 4)
            }

            Spacer()

            MascotMark(size: 72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private extension MetricKind {
    var tint: Color {
        switch self {
        case .steps: .green
        case .sleep: .indigo
        case .restingHeartRate: .red
        case .hrv: .cyan
        }
    }
}

private extension SleepStageKind {
    var tint: Color {
        switch self {
        case .awake: .orange
        case .light: .blue
        case .rem: .purple
        case .deep: .indigo
        }
    }
}

private extension WidgetSyncStatus {
    var tint: Color {
        switch self {
        case .current: .green
        case .stale: .orange
        case .offline: .orange
        case .updateFailed: .red
        case .reconnectRequired: .red
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
            preview(.updateFailed, name: "5 · Update Failed")
            preview(.reconnectRequired, name: "6 · Reconnect Required")
            preview(.initial, name: "7 · Initial")
            preview(.permissionRequired, name: "Permission Required")
            preview(.missingSleep, name: "Sleep · Missing")
            preview(.sleepStagesProcessing, name: "Sleep · Stages Processing")
            preview(.sleepStagesUnavailable, name: "Sleep · Stages Unavailable")
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
