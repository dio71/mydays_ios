import SwiftUI
import UserNotifications

struct SettingsView: View {

    // 개발/테스트용 데이터 삭제 confirm.
    @State private var showWipeConfirm = false
    // 아이콘 export 결과 — 비어있지 않으면 ShareLink 노출.
    @State private var exportedIconURL: URL?
    // 건강 앱 이동 안내 alert — 권한 확인 row 탭 시 path 안내.
    @State private var showHealthAppPathAlert = false
    // Dev: 현재 OS pending 알림 갯수 — 모니터링용. .task / refresh로 갱신.
    @State private var pendingNotificationCount: Int = 0

    @Environment(\.openURL) private var openURL

    // 온보딩 재진입용 — false로 toggle하면 WindowGroup이 OnboardingView 표시.
    @AppStorage(UIStateKey.onboardingShown) private var onboardingShown: Bool = false

    // 사용자 테마 설정 — MyDaysApp의 @AppStorage와 같은 키 → 즉시 sync.
    // store: .appShared — App Group 공유. 위젯에서도 같은 값 읽음.
    @AppStorage(AppThemeKey.tintPreset, store: .appShared)
    private var tintPresetRaw: String = TintPreset.blue.rawValue
    @AppStorage(AppThemeKey.appearanceMode, store: .appShared)
    private var appearanceModeRaw: String = AppearanceMode.system.rawValue

    var body: some View {
        Form {
            Section("settings.section.appearance") {
                // Tint preset(8색 chip) + Appearance mode(3 chip) — 한 VStack에 묶어 사이 row 분리선 제거.
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ForEach(TintPreset.allCases) { preset in
                            tintColorChip(preset)
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(AppearanceMode.displayOrder) { mode in
                            appearanceModeChip(mode)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("settings.section.sync") {
                Text(verbatim: "iCloud (CloudKit)")
                    .foregroundStyle(.secondary)
            }
            Section("settings.section.organize") {
                NavigationLink("settings.categories") {
                    CategoryListView()
                }
            }
            Section("settings.section.permission") {
                // 앱 권한: 마이크 / 음성 인식 / 알림 등 — app-settings: deep link 노출.
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Text("settings.permission.app")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                // 건강 앱 권한: HealthKit은 app-settings에 안 보임 → 건강 앱으로 직접 이동.
                // 곧바로 이동하지 않고 path 안내 alert 거침 (건강 앱 안에서 MyDays까지 깊이 들어가야 함).
                Button {
                    showHealthAppPathAlert = true
                } label: {
                    HStack {
                        Text("settings.permission.health")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            Section("settings.section.activity") {
                // RC 기반 활동 기록 — 목표·할일 정체성 분리 (필터 차원 다름).
                NavigationLink("settings.history.goal") {
                    ActivityHistoryView(item: nil, scope: .goal)
                }
                NavigationLink("settings.history.todo") {
                    ActivityHistoryView(item: nil, scope: .todo)
                }
                // ItemEvent 기반 lifecycle 로그 — 사용자 액션 / 시스템 자동 처리 기록.
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
                // 온보딩 다시 보기 — false로 set하면 WindowGroup이 OnboardingView 표시.
                Button {
                    onboardingShown = false
                } label: {
                    Label {
                        Text(verbatim: "온보딩 다시 보기")
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                }
                // OS pending 알림 갯수 — 64개 한계 모니터링용. 탭하면 즉시 refresh.
                Button {
                    refreshPendingCount()
                } label: {
                    HStack {
                        Text(verbatim: "Pending 알림")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(verbatim: "\(pendingNotificationCount) / 64")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
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
        // iPad/regular size class에서 content 폭 cap — 가독성.
        .iPadContentWidth()
        .navigationTitle("settings.title")
        .task {
            refreshPendingCount()
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
        // 건강 앱 경로 안내 — 건강 앱 안에서 MyDays 권한까지 직접 navigate해야 함 (deep link 불가).
        .alert(
            "permission.health.dialog.title",
            isPresented: $showHealthAppPathAlert
        ) {
            Button("common.cancel", role: .cancel) {}
            Button("permission.health.dialog.confirm") {
                if let url = URL(string: "x-apple-health://") {
                    openURL(url)
                }
            }
        } message: {
            Text("permission.health.dialog.message")
        }
    }

    /// Tint color chip — 30pt 원, 선택 시 흰 체크 표시.
    private func tintColorChip(_ preset: TintPreset) -> some View {
        let selected = tintPresetRaw == preset.rawValue
        return Button {
            tintPresetRaw = preset.rawValue
        } label: {
            Circle()
                .fill(preset.color)
                .frame(width: 30, height: 30)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .accessibilityLabel(Text(preset.labelKey))
        }
        .buttonStyle(.plain)
    }

    /// Appearance mode chip — text label capsule (라이트/다크/시스템).
    private func appearanceModeChip(_ mode: AppearanceMode) -> some View {
        let selected = appearanceModeRaw == mode.rawValue
        return Button {
            appearanceModeRaw = mode.rawValue
        } label: {
            Text(mode.labelKey)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(selected ? Color.accentColor : Color(.systemGray5)))
                .overlay {
                    if !selected {
                        Capsule().stroke(Color(.systemGray3), lineWidth: 0.5)
                    }
                }
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    /// OS pending 알림 갯수 fetch — 64개 한계 모니터링용. Dev row 탭 / view appear 시 호출.
    private func refreshPendingCount() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            DispatchQueue.main.async {
                pendingNotificationCount = requests.count
            }
        }
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
