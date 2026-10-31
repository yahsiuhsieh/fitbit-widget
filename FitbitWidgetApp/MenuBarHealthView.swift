import AppKit
import SwiftUI

struct MenuBarHealthView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: CompanionAppModel
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let snapshot = model.resolvedSnapshot {
                        if model.state.selection.contains(.sleep) {
                            sleepSection(snapshot.sleep)
                        }
                        ForEach(model.state.selection.metrics.filter { $0 != .sleep }) { metric in
                            dailyRow(metric, state: dailyState(metric, snapshot: snapshot))
                        }
                        freshness(snapshot)
                    } else {
                        initialState
                    }
                }
                .padding(16)
            }
            .frame(height: contentHeight)
            Divider()
            actions.padding(12)
        }
        .frame(width: 340)
        .background(NativeWindowObserver { model.setPopoverVisible($0) }.frame(width: 0, height: 0))
        .onDisappear { model.setPopoverVisible(false) }
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Health at a glance")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Text(model.evaluationDate, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MascotMark(size: 30)
        }
    }

    private var contentHeight: CGFloat {
        let desired: CGFloat
        if let snapshot = model.resolvedSnapshot {
            let dailyCount = model.state.selection.metrics.filter { $0 != .sleep }.count
            let sleepHeight: CGFloat
            switch snapshot.sleep {
            case let .value(session):
                if case .available = session.stages { sleepHeight = 170 }
                else { sleepHeight = 142 }
            case .noData, .permissionRequired: sleepHeight = 104
            }
            desired = 62 + CGFloat(dailyCount) * 68 + (model.state.selection.contains(.sleep) ? sleepHeight : 0)
        } else { desired = 182 }
        return min(desired, max(180, (NSScreen.main?.visibleFrame.height ?? 800) - 220))
    }

    private func dailyState(_ metric: MetricKind, snapshot: ResolvedHealthSnapshot) -> MetricState<DailyMetricValue> {
        switch metric {
        case .steps: snapshot.steps
        case .restingHeartRate: snapshot.restingHeartRate
        case .hrv: snapshot.hrv
        case .sleep: .noData
        }
    }

    private func dailyRow(_ metric: MetricKind, state: MetricState<DailyMetricValue>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: metric.symbolName)
                .foregroundStyle(metric.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(metric.title).font(.subheadline.weight(.medium))
                switch state {
                case let .value(value):
                    if let source = metricSourceDateText(value, metric: metric, evaluationDate: model.evaluationDate) {
                        Text(source).font(.caption2).foregroundStyle(.secondary)
                    }
                case .noData:
                    Text(metric == .steps ? "No Data Today" : "No Recent Data")
                        .font(.caption2).foregroundStyle(.secondary)
                case .permissionRequired:
                    Text("Permission Required").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if case let .value(value) = state {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(value.value.formatted(.number.grouping(.automatic)))
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                    Text(metric.unit).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("—").font(.title2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func sleepSection(_ state: MetricState<SleepSession>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sleep", systemImage: MetricKind.sleep.symbolName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            switch state {
            case let .value(session):
                HStack(alignment: .firstTextBaseline) {
                    Text(durationText(session.minutesAsleep))
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                    Spacer()
                }
                HStack(spacing: 6) {
                    Text(timeText(session.start))
                    Image(systemName: "arrow.right").accessibilityLabel("to")
                    Text(timeText(session.end))
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                SleepStageContent(state: session.stages)
                    .fixedSize(horizontal: false, vertical: true)
            case .noData:
                missingSleep("No Recent Data")
            case .permissionRequired:
                missingSleep("Permission Required")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func missingSleep(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("—").font(.title2)
            Text(message).font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private func freshness(_ snapshot: ResolvedHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if case let .data(data) = model.state.content {
                let issue = model.needsReconnection ? SyncIssue.reconnectRequired : data.lastSyncIssue
                let titles = freshnessTitles(issue: issue, isStale: snapshot.isStale)
                if !titles.isEmpty {
                    Label(titles.joined(separator: " · "),
                          systemImage: issue?.symbolName ?? "clock.badge.exclamationmark.fill")
                        .foregroundStyle(issue?.tint ?? .orange)
                }
            }
            UpdatedAgeText(lastSuccessfulUpdate: snapshot.lastSuccessfulUpdate)
                .foregroundStyle(.secondary)
            if model.state.sync.nextAttempt.map({ $0 > model.evaluationDate }) == true {
                Text(model.refreshHelp).foregroundStyle(.secondary)
            }
            if !model.hasSharedStore {
                Text("Shared data unavailable · Open Settings").foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var initialState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: model.needsReconnection ? "person.crop.circle.badge.exclamationmark" : "heart.text.square.fill")
                .font(.title).foregroundStyle(.tint).accessibilityHidden(true)
            Text(initialTitle).font(.headline)
            Text(initialDetail).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings…", action: openStatus)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var initialTitle: String {
        if !model.hasSharedStore { return "Health Data Unavailable" }
        if model.needsReconnection { return "Reconnect in App" }
        switch model.state.content {
        case .unconnected: return "Connect Google Health in App"
        case .accountNotLinked: return "Google Health Profile Required"
        case .initialSyncFailed: return "Unable to Load Data"
        case .data: return "Open Settings"
        }
    }

    private var initialDetail: String {
        if !model.hasSharedStore { return "Open Settings to review the app’s shared data access." }
        if model.needsReconnection { return "Connect Google Health again in Settings to resume updates." }
        switch model.state.content {
        case .unconnected: return "Connect once to see your selected metrics here. No desktop Widget is required."
        case .accountNotLinked: return "Set up Google Health on a compatible phone using the same Google account."
        case .initialSyncFailed: return "Open Settings to review the connection or try refreshing again."
        case .data: return "Review your connection and metric selection in Settings."
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: { model.refresh() }) {
                Label(model.activity == .refreshing ? "Refreshing…" : "Refresh Now", systemImage: "arrow.clockwise")
            }
            .disabled(!model.canRefresh)
            .help(model.refreshHelp)
            if model.activity != .idle {
                ProgressView().controlSize(.mini).accessibilityLabel(model.connectionTitle)
            }
            Spacer(minLength: 0)
            Button(action: openStatus) { Label("Open Settings…", systemImage: "gearshape") }
                .labelStyle(.iconOnly).help("Open Settings…")
            Menu {
                Button("Quit Fitbit Widget") { NSApplication.shared.terminate(nil) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
    }

    private func openStatus() {
        dismiss()
        openSettings()
    }
}
