import SwiftUI
import MessageUI

struct SettingsView: View {

    // 프로 플랜 전용 기능 잠금 안내 alert (테마 색상 등).
    @State private var showProAlert = false
    @State private var proAlertFeature: ProFeature = .theme
    // 프로 플랜 안내(Paywall) sheet.
    @State private var showPaywall = false
    // 피드백 인앱 작성 메일 sheet. 메일 계정 없으면 mailto fallback.
    @State private var showFeedbackMail = false
    // 도움말 — 호스팅 FAQ를 앱 내 Safari로 표시.
    @State private var showHelp = false

    @Environment(\.openURL) private var openURL

    // 온보딩 재진입용 — false로 set하면 WindowGroup이 OnboardingView 표시.
    @AppStorage(UIStateKey.onboardingShown) private var onboardingShown: Bool = false
    // 프로 언락 상태 — 상단 진입점 표시 + 테마 chip 잠금 판정.
    @AppStorage(PremiumKey.isUnlocked, store: .appShared) private var premiumUnlocked: Bool = false
    // 마지막 CloudKit 동기화 시각.
    @AppStorage(PersistenceController.lastSyncDateKey) private var lastSyncTimestamp: Double = 0
    // 테마 설정 — App Group 공유(위젯 일관).
    @AppStorage(AppThemeKey.tintPreset, store: .appShared)
    private var tintPresetRaw: String = TintPreset.coral.rawValue
    @AppStorage(AppThemeKey.appearanceMode, store: .appShared)
    private var appearanceModeRaw: String = AppearanceMode.system.rawValue

    var body: some View {
        Form {
            // 프로 플랜 상시 진입점.
            Section {
                if premiumUnlocked {
                    Label {
                        Text("paywall.already").foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "crown.fill").foregroundStyle(Color.accentColor)
                    }
                } else {
                    Button {
                        showPaywall = true
                    } label: {
                        HStack {
                            Label {
                                Text("pro.upgrade.cta").foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "crown.fill").foregroundStyle(Color.accentColor)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // 앱 색상 — Tint preset(8색) + Appearance mode(3 chip).
            Section("settings.section.appearance") {
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

            // 분류.
            Section("settings.section.organize") {
                NavigationLink("settings.categories") { CategoryListView() }
            }

            // 활동 기록 — 목표 / 할일 (활동 로그는 개발자 메뉴로 이동).
            Section("settings.section.activity") {
                NavigationLink("settings.history.goal") {
                    ActivityHistoryView(item: nil, scope: .goal)
                }
                NavigationLink("settings.history.todo") {
                    ActivityHistoryView(item: nil, scope: .todo)
                }
            }

            // 도움말 및 피드백 — 활동 기록 아래. 아이콘 없이 텍스트 row.
            Section("settings.section.help_feedback") {
                Button {
                    showHelp = true
                } label: {
                    Text("settings.help")
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    onboardingShown = false
                } label: {
                    Text("settings.onboarding_replay")
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    sendFeedback()
                } label: {
                    Text("settings.feedback")
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // 동기화.
            Section("settings.section.sync") {
                Text(verbatim: "iCloud (CloudKit)")
                    .foregroundStyle(.secondary)
                HStack {
                    Text("settings.sync.last_synced")
                    Spacer()
                    Text(verbatim: lastSyncedText).foregroundStyle(.secondary)
                }
            }

            // 정보 → 정보 및 권한 하위 페이지.
            Section("settings.section.info") {
                NavigationLink {
                    InfoPermissionView()
                } label: {
                    Text("settings.info_permission")
                }
            }
        }
        .iPadContentWidth()
        .navigationTitle("settings.title")
        // 프로 플랜 전용 기능 잠금 안내 (테마 색상 등).
        .alert(
            Text(verbatim: proAlertFeature.alertTitle),
            isPresented: $showProAlert
        ) {
            Button("pro.upgrade.cta") { showPaywall = true }
            Button("common.close", role: .cancel) {}
        } message: {
            Text(verbatim: proAlertFeature.alertMessage)
        }
        // 프로 플랜 안내(Paywall).
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        // 피드백 인앱 작성 메일.
        .sheet(isPresented: $showFeedbackMail) {
            MailComposeView { showFeedbackMail = false }
                .ignoresSafeArea()
        }
        // 도움말 FAQ — 앱 내 Safari.
        .sheet(isPresented: $showHelp) {
            SafariView(url: AppLinks.help)
                .ignoresSafeArea()
        }
    }

    // MARK: - 피드백

    /// 메일 계정 있으면 인앱 작성, 없으면 mailto.
    private func sendFeedback() {
        if MFMailComposeViewController.canSendMail() {
            showFeedbackMail = true
        } else if let url = FeedbackMail.mailtoURL() {
            openURL(url)
        }
    }

    // MARK: - 앱 색상 chips

    /// Tint color chip — 30pt 원, 선택 시 흰 체크. Pro 아니면 기본(coral) 외 색 잠금.
    private func tintColorChip(_ preset: TintPreset) -> some View {
        let selected = tintPresetRaw == preset.rawValue
        let locked = !premiumUnlocked && preset != .coral
        return Button {
            if locked {
                proAlertFeature = .theme
                showProAlert = true
            } else {
                tintPresetRaw = preset.rawValue
            }
        } label: {
            Circle()
                .fill(preset.color)
                .frame(width: 30, height: 30)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    } else if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
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

    // MARK: - 동기화 시각

    /// 마지막 동기화 시각 표시 — 기록 없으면 "아직 없음", 오늘은 상대시간, 날짜 넘으면 절대.
    private var lastSyncedText: String {
        guard lastSyncTimestamp > 0 else {
            return String(localized: "settings.sync.never")
        }
        let date = Date(timeIntervalSinceReferenceDate: lastSyncTimestamp)
        let now = Date()
        if abs(now.timeIntervalSince(date)) < 1 {
            return String(localized: "settings.sync.just_now")
        }
        if Calendar.current.isDate(date, inSameDayAs: now) {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale.current
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: now)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MdjmE" : "yMdjm")
        return formatter.string(from: date)
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
