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
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Item.completeExpiredRoutines(in: context)
            }
        }
    }
}

#Preview {
    RootView()
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
