import SwiftUI

@main
struct MyDaysApp: App {

    private let persistence = PersistenceController.shared

    // 사용자 테마 설정 — Settings에서 변경, 앱 전체 propagate.
    // store: .appShared — App Group 공유 suite. 위젯 process도 같은 값을 읽어 일관 tint 적용.
    @AppStorage(AppThemeKey.tintPreset, store: .appShared)
    private var tintPresetRaw: String = TintPreset.blue.rawValue
    @AppStorage(AppThemeKey.appearanceMode, store: .appShared)
    private var appearanceModeRaw: String = AppearanceMode.system.rawValue

    private var tintColor: Color {
        (TintPreset(rawValue: tintPresetRaw) ?? .blue).color
    }
    private var colorScheme: ColorScheme? {
        (AppearanceMode(rawValue: appearanceModeRaw) ?? .system).colorScheme
    }

    init() {
        // NotificationService 싱글톤 strict init — UNUserNotificationCenter delegate 즉시 등록.
        // 앱이 알림 탭으로 launch되는 경우에도 willPresent/handler가 정상 호출되도록 보장.
        _ = NotificationService.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistence.viewContext)
                .tint(tintColor)
                .preferredColorScheme(colorScheme)
        }
    }
}
