import SwiftUI

struct RootView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSize
    // 오늘 day-of-month — Today 탭 아이콘 `N.calendar` 동적 표시용.
    // 자정 넘김(NSCalendarDayChanged) + foreground 복귀 시 갱신.
    @State private var todayDay: Int = Calendar.current.component(.day, from: Date())
    // iPad sidebar 선택 항목.
    @State private var sidebarSelection: SidebarItem? = .today

    var body: some View {
        Group {
            // Regular(iPad/Mac Catalyst): NavigationSplitView 사이드바 + 디테일.
            // Compact(iPhone): TabView 4 탭.
            if hSize == .regular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            todayDay = Calendar.current.component(.day, from: Date())
        }
        .task {
            // routine 자동 status 동기화는 사용자 trigger(ListView.task / AddItemView.save) 시점에만 수행 —
            // launch 시 호출 제거. NTD 자동 완료는 알림/위젯 정확성 위해 유지.
            Item.completeFinishedNTDs(in: context)
            // CloudKit 충돌 등으로 같은 anchor에 reminder 중복이 쌓여 동일 알림이 N개 fire되는 문제 정리.
            // 변경이 있을 때만 save + 알림 재동기화 (no-op이 일반).
            Item.dedupeReminders(in: context)
            // routine 알림 refill — 4개 occurrence window를 다시 채워 long-term routine이 끊기지 않게.
            Item.refreshAllRoutineNotifications(in: context)
            // 첫 launch 시 알림 권한 명시 요청.
            // 이미 결정된 경우(허용/거부) 무동작. 처음이면 시스템 prompt.
            await NotificationService.shared.requestAuthorization()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Item.completeFinishedNTDs(in: context)
                // 백그라운드 동안 fire된 알림이 빠진 슬롯을 다시 채움.
                Item.refreshAllRoutineNotifications(in: context)
                // 백그라운드 자정 통과한 경우 탭 아이콘 갱신.
                todayDay = Calendar.current.component(.day, from: Date())
            }
        }
    }

    // MARK: - iPhone (compact)

    @ViewBuilder
    private var iPhoneLayout: some View {
        // iOS 26 — WindowGroup의 `.tint()`이 TabView 내부 NavigationStack 본문에
        // 항상 propagate되지 않는 케이스(week strip / FAB / ItemRow의 Color.accentColor가
        // 시스템 blue로 fallback)가 관찰됨. 각 NavigationStack에 .appTint() 명시 적용해
        // body의 Color.accentColor가 사용자 테마 색을 정확히 반영하도록 보장.
        TabView {
            NavigationStack { TodayView() }
                .appTint()
                .tabItem { Label("tab.today", systemImage: "\(todayDay).calendar") }

            NavigationStack { ListView() }
                .appTint()
                .tabItem { Label("tab.list", systemImage: "list.bullet") }

            NavigationStack { ArchiveView() }
                .appTint()
                .tabItem { Label("tab.archive", systemImage: "archivebox") }

            NavigationStack { SettingsView() }
                .appTint()
                .tabItem { Label("tab.settings", systemImage: "gearshape") }
        }
    }

    // MARK: - iPad / Mac Catalyst (regular)

    @ViewBuilder
    private var iPadLayout: some View {
        NavigationSplitView {
            // 사이드바 — List(selection:) + ForEach + .tag(item).
            // .tag(item)로 row의 selection 값 명시 — Identifiable id만으로는 selection 매칭 안 됨.
            List(selection: $sidebarSelection) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.labelKey, systemImage: item.icon(todayDay: todayDay))
                        .tag(item)
                }
            }
            .navigationTitle("app.name")
        } detail: {
            // 디테일 — 선택 항목 별 view. 각 view는 NavigationStack 안에 두어 toolbar/title 정상 동작.
            NavigationStack {
                detailView
            }
            .appTint()
        }
    }

    /// 사이드바 선택에 따른 디테일 view. Group으로 감싸 @ViewBuilder switch 안정화.
    @ViewBuilder
    private var detailView: some View {
        switch sidebarSelection ?? .today {
        case .today:    TodayView()
        case .list:     ListView()
        case .archive:  ArchiveView()
        case .settings: SettingsView()
        }
    }
}

/// iPad/Mac Catalyst 사이드바 항목.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case today, list, archive, settings

    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .today:    return "tab.today"
        case .list:     return "tab.list"
        case .archive:  return "tab.archive"
        case .settings: return "tab.settings"
        }
    }

    /// 오늘 탭은 day-of-month 동적 아이콘, 그 외 고정.
    func icon(todayDay: Int) -> String {
        switch self {
        case .today:    return "\(todayDay).calendar"
        case .list:     return "list.bullet"
        case .archive:  return "archivebox"
        case .settings: return "gearshape"
        }
    }
}

#Preview {
    RootView()
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
