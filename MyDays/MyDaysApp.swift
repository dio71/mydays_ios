import SwiftUI

@main
struct MyDaysApp: App {

    private let persistence = PersistenceController.shared

    init() {
        // NotificationService 싱글톤 strict init — UNUserNotificationCenter delegate 즉시 등록.
        // 앱이 알림 탭으로 launch되는 경우에도 willPresent/handler가 정상 호출되도록 보장.
        _ = NotificationService.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistence.viewContext)
        }
    }
}
