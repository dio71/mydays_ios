import SwiftUI

struct RootView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NavigationStack { TodayView() }
                .tabItem { Label("tab.today", systemImage: "checklist") }

            NavigationStack { ListView() }
                .tabItem { Label("tab.list", systemImage: "list.bullet") }

            NavigationStack { ArchiveView() }
                .tabItem { Label("tab.archive", systemImage: "archivebox") }

            NavigationStack { SettingsView() }
                .tabItem { Label("tab.settings", systemImage: "gearshape") }
        }
        .task {
            Item.completeExpiredRoutines(in: context)
            Item.completeFinishedNTDs(in: context)
            // routine 알림 refill — 4개 occurrence window를 다시 채워 long-term routine이 끊기지 않게.
            Item.refreshAllRoutineNotifications(in: context)
            // 첫 launch 시 알림 권한 명시 요청.
            // 이미 결정된 경우(허용/거부) 무동작. 처음이면 시스템 prompt.
            await NotificationService.shared.requestAuthorization()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Item.completeExpiredRoutines(in: context)
                Item.completeFinishedNTDs(in: context)
                // 백그라운드 동안 fire된 알림이 빠진 슬롯을 다시 채움.
                Item.refreshAllRoutineNotifications(in: context)
            }
        }
    }
}

#Preview {
    RootView()
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
