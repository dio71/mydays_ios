import SwiftUI

struct SettingsView: View {

    var body: some View {
        Form {
            Section("settings.section.sync") {
                Text(verbatim: "iCloud (CloudKit)")
                    .foregroundStyle(.secondary)
            }
            Section("settings.section.activity") {
                NavigationLink("settings.activity_log") {
                    ActivityLogView()
                }
            }
            Section("settings.section.info") {
                HStack {
                    Text("settings.label.version")
                    Spacer()
                    Text(verbatim: versionString)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("settings.title")
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
