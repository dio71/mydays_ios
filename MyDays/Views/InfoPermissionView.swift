import SwiftUI
import UserNotifications

// MARK: - InfoPermissionView
//
// Settings "정보 및 권한" → 한 단계 안 페이지.
// 상단 프라이버시 선언 + 권한 / 정보 / 데이터 / 개발자(#if DEBUG) 섹션.

struct InfoPermissionView: View {

    @Environment(\.openURL) private var openURL
    @Environment(\.managedObjectContext) private var context

    @State private var showHealthAppPathAlert = false
    @State private var showPrivacyPolicy = false
    @State private var showWipeConfirm = false
    // 데이터 내보내기 — 생성된 JSON 파일을 공유 시트로.
    @State private var exportFile: ExportFile?

    private struct ExportFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    // 개발자(#if DEBUG) 용
    @State private var pendingNotificationCount = 0
    @State private var exportedIconURL: URL?
    @AppStorage(PremiumKey.isUnlocked, store: .appShared) private var premiumUnlocked = false

    var body: some View {
        Form {
            // 권한.
            Section("settings.section.permission") {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    navRow("settings.permission.app")
                }
                .buttonStyle(.plain)
                Button {
                    showHealthAppPathAlert = true
                } label: {
                    navRow("settings.permission.health")
                }
                .buttonStyle(.plain)
            }

            // 정보.
            Section("settings.section.info") {
                Button {
                    showPrivacyPolicy = true
                } label: {
                    navRow("settings.privacy_policy")
                }
                .buttonStyle(.plain)
                HStack {
                    Text("settings.label.version")
                    Spacer()
                    Text(verbatim: versionString)
                        .foregroundStyle(.secondary)
                }
            }

            // 데이터.
            Section("settings.section.data") {
                // 데이터 내보내기 — 전체 JSON 백업 → 공유 시트.
                Button {
                    if let url = DataExportService.exportJSON(in: context) {
                        exportFile = ExportFile(url: url)
                    }
                } label: {
                    HStack {
                        Text("settings.data.export")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    showWipeConfirm = true
                } label: {
                    Text("settings.data.delete_all")
                }
            }

            #if DEBUG
            developerSection
            #endif
        }
        .iPadContentWidth()
        .navigationTitle("settings.info_permission")
        .navigationBarTitleDisplayMode(.inline)
        .task { refreshPendingCount() }
        .sheet(isPresented: $showPrivacyPolicy) {
            SafariView(url: AppLinks.privacyPolicy)
                .ignoresSafeArea()
        }
        .sheet(item: $exportFile) { file in
            ShareSheet(items: [file.url])
        }
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
        .alert("permission.health.dialog.title", isPresented: $showHealthAppPathAlert) {
            Button("common.cancel", role: .cancel) {}
            Button("permission.health.dialog.confirm") {
                if let url = URL(string: "x-apple-health://") { openURL(url) }
            }
        } message: {
            Text("permission.health.dialog.message")
        }
    }

    // MARK: - 개발자 (DEBUG 전용)

    #if DEBUG
    @ViewBuilder
    private var developerSection: some View {
        Section(header: Text(verbatim: "개발자")) {
            Toggle(isOn: $premiumUnlocked) {
                Label {
                    Text(verbatim: "프로 플랜 잠금 해제 (테스트)").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: premiumUnlocked ? "lock.open.fill" : "lock.fill")
                }
            }
            NavigationLink("settings.activity_log") { ActivityLogView() }
            Button {
                refreshPendingCount()
            } label: {
                HStack {
                    Text(verbatim: "Pending 알림").foregroundStyle(.primary)
                    Spacer()
                    Text(verbatim: "\(pendingNotificationCount) / 64")
                        .foregroundStyle(.secondary).monospacedDigit()
                    Image(systemName: "arrow.clockwise").font(.footnote).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            // 앱 아이콘 export
            HStack {
                Spacer()
                AppIconView(size: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
    #endif

    // MARK: - 부속

    private func navRow(_ key: LocalizedStringKey) -> some View {
        HStack {
            Text(key).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    private func refreshPendingCount() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            DispatchQueue.main.async { pendingNotificationCount = requests.count }
        }
    }
}
