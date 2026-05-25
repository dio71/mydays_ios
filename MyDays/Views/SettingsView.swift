import SwiftUI

struct SettingsView: View {

    // 개발/테스트용 데이터 삭제 confirm.
    @State private var showWipeConfirm = false
    // 아이콘 export 결과 — 비어있지 않으면 ShareLink 노출.
    @State private var exportedIconURL: URL?

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

            // 임시: 개발/테스트용. CloudKit이 데이터를 보관하므로 재설치해도 복원됨 → 명시적 삭제 필요.
            // 정식 출시 전 제거 또는 debug 빌드에서만 노출하도록 검토.
            Section(header: Text(verbatim: "Dev")) {
                Button(role: .destructive) {
                    showWipeConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        Label {
                            Text(verbatim: "모든 데이터 삭제")
                        } icon: {
                            Image(systemName: "trash")
                        }
                        Spacer()
                    }
                }
            }

            // 아이콘 시안 — 미리보기 + 1024×1024 PNG export.
            // 색·아이콘 조정은 AppIconView 안의 상수만 바꾸면 됨.
            Section(header: Text(verbatim: "App Icon")) {
                HStack {
                    Spacer()
                    AppIconView(size: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    Spacer()
                }
                .padding(.vertical, 4)
                Button {
                    exportedIconURL = AppIconBuilder.exportPNG()
                } label: {
                    Label("1024×1024 PNG 생성", systemImage: "square.and.arrow.down")
                }
                if let url = exportedIconURL {
                    ShareLink(item: url) {
                        Label("아이콘 PNG 공유", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("settings.title")
        .alert(Text(verbatim: "모든 데이터를 삭제할까요?"), isPresented: $showWipeConfirm) {
            Button("common.cancel", role: .cancel) {}
            Button(role: .destructive) {
                PersistenceController.shared.deleteAllData()
            } label: {
                Text(verbatim: "삭제")
            }
        } message: {
            Text(verbatim: "iCloud에 동기화된 데이터도 함께 삭제됩니다. 되돌릴 수 없습니다.")
        }
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
