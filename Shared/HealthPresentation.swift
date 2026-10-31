import SwiftUI

// The system advances this archived text without running the App or Widget provider.
struct UpdatedAgeText: View {
    let lastSuccessfulUpdate: Date

    var body: some View {
        let style = SystemFormatStyle.DateReference(
            to: lastSuccessfulUpdate, allowedFields: [.minute],
            maxFieldCount: 1, thresholdField: .year
        )
        Text("Updated \(Text(.currentDate, format: style))")
            .monospacedDigit()
            .multilineTextAlignment(.leading)
            .help(lastSuccessfulUpdate.formatted(date: .abbreviated, time: .shortened))
    }
}

// Small presentation primitives shared by the two native surfaces; layouts stay separate.
struct SleepStageContent: View {
    let state: SleepStageState

    var body: some View {
        switch state {
        case let .available(stages):
            VStack(alignment: .leading, spacing: 8) {
                SleepStageBar(stages: stages)

                HStack(spacing: 8) {
                    ForEach(SleepStageKind.allCases) { stage in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(stage.tint)
                                    .frame(width: 7, height: 7)
                                Text(stage.title)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }

                            Text(durationText(stages.minutes(for: stage)))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }

        case .processing:
            stageUnavailableLabel("Sleep stages are processing", symbol: "clock")

        case .unavailable:
            stageUnavailableLabel("Sleep stages unavailable", symbol: "minus.circle")
        }
    }

    private func stageUnavailableLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SleepStageBar: View {
    let stages: SleepStages

    private var visibleStages: [SleepStageKind] {
        SleepStageKind.allCases.filter { (stages.minutes(for: $0) ?? 0) > 0 }
    }

    private var totalMinutes: Int {
        max(visibleStages.reduce(0) { $0 + (stages.minutes(for: $1) ?? 0) }, 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let spacing = CGFloat(max(visibleStages.count - 1, 0)) * 4
            let availableWidth = max(proxy.size.width - spacing, 0)

            HStack(spacing: 4) {
                ForEach(visibleStages) { stage in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(stage.tint)
                        .frame(
                            width: max(
                                6,
                                availableWidth * CGFloat(stages.minutes(for: stage) ?? 0) / CGFloat(totalMinutes)
                            )
                        )
                }
            }
        }
        .frame(height: 11)
        .accessibilityHidden(true)
    }
}

struct MascotMark: View {
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

func durationText(_ minutes: Int?) -> String {
    guard let minutes else { return "—" }
    guard minutes > 0 else { return "0 min" }

    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
}

func timeText(_ time: ZonedInstant) -> String {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    formatter.timeZone = TimeZone(secondsFromGMT: time.utcOffsetSeconds)
    return formatter.string(from: time.instant)
}

extension MetricKind {
    var unit: String {
        switch self {
        case .steps: "steps"
        case .restingHeartRate: "bpm"
        case .hrv: "ms"
        case .sleep: ""
        }
    }

    var tint: Color {
        switch self {
        case .steps: .green
        case .sleep: .indigo
        case .restingHeartRate: .red
        case .hrv: .cyan
        }
    }
}

func metricSourceDateText(_ value: DailyMetricValue, metric: MetricKind, evaluationDate: Date) -> String? {
    guard metric == .restingHeartRate || metric == .hrv else { return nil }
    let calendar = SharedConfiguration.localCalendar
    guard value.sourceDay != LocalDay(date: evaluationDate, calendar: calendar),
          let sourceDate = value.sourceDay.date(in: calendar) else { return nil }
    return "Source \(sourceDate.formatted(.dateTime.month(.abbreviated).day()))"
}

func freshnessTitles(issue: SyncIssue?, isStale: Bool) -> [String] {
    var titles = issue.map { [$0.title] } ?? []
    if isStale { titles.append("Stale") }
    return titles
}

extension SleepStageKind {
    var tint: Color {
        switch self {
        case .awake: .orange
        case .light: .blue
        case .rem: .purple
        case .deep: .indigo
        }
    }
}

extension SyncIssue {
    var title: String {
        switch self {
        case .offline: "Offline"
        case .updateFailed: "Update Failed"
        case .reconnectRequired: "Reconnect in App"
        }
    }

    var symbolName: String {
        switch self {
        case .offline: "wifi.slash"
        case .updateFailed: "exclamationmark.triangle.fill"
        case .reconnectRequired: "person.crop.circle.badge.exclamationmark.fill"
        }
    }

    var tint: Color {
        switch self {
        case .offline: .orange
        case .updateFailed, .reconnectRequired: .red
        }
    }
}
