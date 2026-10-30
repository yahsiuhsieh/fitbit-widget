import SwiftUI

struct CompanionAppView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Fitbit Widget")
                        .font(.title2.weight(.semibold))

                    Text("Widget UI prototype")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("Mock data is ready", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                Text("This milestone contains the native Large widget and its visual states. Google Health connection and settings arrive in a later milestone.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add the widget")
                        .font(.headline)

                    Label("Control-click the desktop and choose Edit Widgets.", systemImage: "1.circle.fill")
                    Label("Search for Fitbit Widget.", systemImage: "2.circle.fill")
                    Label("Add the Large widget to the desktop.", systemImage: "3.circle.fill")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack(spacing: 8) {
                statusPill("macOS 14+", icon: "macbook")
                statusPill("Mock data", icon: "sparkles")
                statusPill("Large", icon: "rectangle.split.2x2")
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 560, height: 420)
    }

    private func statusPill(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
    }
}

struct CompanionAppView_Previews: PreviewProvider {
    static var previews: some View {
        CompanionAppView()
    }
}
