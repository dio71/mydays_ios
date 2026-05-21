import SwiftUI

struct SettingsView: View {

    var body: some View {
        Form {
            Section("동기화") {
                Text("iCloud (CloudKit)")
                    .foregroundStyle(.secondary)
            }
            Section("활동") {
                NavigationLink("활동 로그") {
                    ActivityLogView()
                }
            }
            Section("정보") {
                HStack {
                    Text("버전")
                    Spacer()
                    Text(versionString)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("설정")
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
