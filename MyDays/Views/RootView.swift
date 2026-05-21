import SwiftUI

struct RootView: View {

    var body: some View {
        TabView {
            NavigationStack { TodayView() }
                .tabItem { Label("오늘", systemImage: "checklist") }

            NavigationStack { ListView() }
                .tabItem { Label("목록", systemImage: "list.bullet") }

            NavigationStack { ArchiveView() }
                .tabItem { Label("보관함", systemImage: "archivebox") }

            NavigationStack { SettingsView() }
                .tabItem { Label("설정", systemImage: "gearshape") }
        }
    }
}

#Preview {
    RootView()
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
