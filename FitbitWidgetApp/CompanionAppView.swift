import SwiftUI
import ServiceManagement

struct CompanionAppView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: CompanionAppModel
    @ObservedObject var preferences: AppPreferences
    @State private var showsDisclosure = false
    @State private var showsResetConfirmation = false
    @State private var showsWidgetHelp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusSection
                metricSelectionSection
                behaviorSection
                widgetHelpSection
                actionSection
            }
            .padding(24)
        }
        .frame(width: 560, height: 700)
        .task { preferences.refreshLoginStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { preferences.refreshLoginStatus() }
        }
        .alert("Connect Google Health", isPresented: $showsDisclosure) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") { model.startConnection() }
        } message: {
            Text("Fitbit Widget reads your steps, sleep, resting heart rate, and HRV for the Menu Bar and optional Widget. Your health data stays encrypted on this Mac and is not shared with an app backend. Delete Local Data removes this Mac’s saved data and connection; access in your Google Account is not revoked.")
        }
        .confirmationDialog(
            "Delete Local Google Health Data?",
            isPresented: $showsResetConfirmation
        ) {
            Button("Delete Local Data", role: .destructive) {
                model.resetLocalData()
            }
        } message: {
            Text("This removes this Mac’s saved connection, permissions, metric selection, and health data. Access in your Google Account is not revoked.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Fitbit Widget")
                    .font(.title2.weight(.semibold))
                Text("Connection and settings")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var statusSection: some View {
        GroupBox("Status") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.connectionTitle)
                            .font(.headline)
                        Text(model.connectionDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }

                Divider()

                LabeledContent("Last Successful Update") {
                    if let updateDate = model.lastSuccessfulUpdate {
                        Text(updateDate, format: .dateTime.month().day().hour().minute())
                            .monospacedDigit()
                    } else {
                        Text("Not yet")
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = model.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metricSelectionSection: some View {
        GroupBox("Metrics") {
            VStack(alignment: .leading, spacing: 9) {
                Text("Choose 1–4 authorized metrics for the Menu Bar and all Widgets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(MetricKind.allCases.indices, id: \.self) { index in
                    let metric = MetricKind.allCases[index]
                    HStack(spacing: 10) {
                        Toggle(isOn: selectionBinding(for: metric)) {
                            Label(metric.title, systemImage: metric.symbolName)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(metricIsDisabled(metric))

                        Spacer()

                        Text(model.state.permissions.allows(metric) ? "Granted" : "Permission Required")
                            .font(.caption)
                            .foregroundStyle(
                                model.state.permissions.allows(metric)
                                    ? Color.secondary
                                    : Color.orange
                            )
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var behaviorSection: some View {
        GroupBox("App Behavior") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show in Menu Bar", isOn: $preferences.showInMenuBar)
                Text("The Menu Bar is available while the app is running. Closing this window keeps it running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Launch at Login", isOn: Binding(
                    get: { preferences.loginStatus == .enabled },
                    set: { preferences.setLaunchAtLogin($0) }
                ))
                .disabled(preferences.isChangingLogin)
                Text("Optional. Starts the app when you log into macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if preferences.loginStatus == .requiresApproval {
                    Text("Launch at Login requires approval in System Settings.")
                        .font(.caption)
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if preferences.loginStatus == .notFound {
                    Text("Launch at Login is unavailable. Try reinstalling the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = preferences.loginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            .toggleStyle(.checkbox)
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var widgetHelpSection: some View {
        DisclosureGroup("Add the Widget (Optional)", isExpanded: $showsWidgetHelp) {
            VStack(alignment: .leading, spacing: 7) {
                Label("Control-click the desktop and choose Edit Widgets.", systemImage: "1.circle.fill")
                Label("Search for Fitbit Widget.", systemImage: "2.circle.fill")
                Label("Add the Large widget.", systemImage: "3.circle.fill")
            }
            .font(.subheadline)
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionSection: some View {
        HStack(spacing: 10) {
            if model.activity != .idle {
                Button("Cancel") { model.cancelActivity() }
                    .buttonStyle(.borderedProminent)
            } else if model.isConnected {
                Button(action: { model.refresh() }) {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRefresh)

                Button(model.needsReconnection ? "Connect Google Health" : "Review Permissions") {
                    showsDisclosure = true
                }
            } else {
                Button("Connect Google Health") { showsDisclosure = true }
                    .buttonStyle(.borderedProminent)
            }

            #if DEBUG
            if !model.isConnected && model.activity == .idle {
                Button("Load Sample Data") { model.loadDevelopmentPreview() }
                    .help("Local development preview only; no token is created.")
            }
            #endif

            Spacer()

            Button(role: .destructive) {
                showsResetConfirmation = true
            } label: {
                Label("Delete Local Data", systemImage: "trash")
            }
            .disabled(!model.hasSharedStore || model.activity != .idle)
        }
        .disabled(!model.hasSharedStore)
    }

    private func selectionBinding(for metric: MetricKind) -> Binding<Bool> {
        Binding(
            get: { model.state.selection.contains(metric) },
            set: { model.updateSelection(metric, isSelected: $0) }
        )
    }

    private func metricIsDisabled(_ metric: MetricKind) -> Bool {
        !model.hasSharedStore
            || model.activity != .idle
            || !model.isConnected
            || !model.state.permissions.allows(metric)
            || (model.state.selection.metrics.count == 1 && model.state.selection.contains(metric))
    }

    private var statusSymbol: String {
        if model.activity != .idle { return "arrow.triangle.2.circlepath" }
        if model.needsReconnection { return SyncIssue.reconnectRequired.symbolName }
        if case let .data(data) = model.state.content, let issue = data.lastSyncIssue { return issue.symbolName }
        return switch model.state.content {
        case .unconnected: "link.badge.plus"
        case .accountNotLinked: "person.crop.circle.badge.exclamationmark"
        case .initialSyncFailed: "exclamationmark.triangle.fill"
        case .data: "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        if model.activity != .idle { return .accentColor }
        if model.needsReconnection { return SyncIssue.reconnectRequired.tint }
        if case let .data(data) = model.state.content, let issue = data.lastSyncIssue { return issue.tint }
        return switch model.state.content {
        case .unconnected: .secondary
        case .accountNotLinked, .initialSyncFailed: .orange
        case .data: .green
        }
    }
}

struct CompanionAppView_Previews: PreviewProvider {
    static var previews: some View {
        CompanionAppView(model: CompanionAppModel(sharedStore: nil), preferences: AppPreferences())
    }
}
