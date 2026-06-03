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
    /// 첫 진입 onboarding 완료 여부. false면 권한 안내 페이지 노출.
    @AppStorage(UIStateKey.onboardingShown)
    private var onboardingShown: Bool = false

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
        // HK background observer 등록 — launch 시 4 source 일괄.
        // 활성 활동 목표가 없는 source도 등록(observer는 cheap, handler에서 active 항목 없으면 skip).
        // 앱이 알림 또는 BG fetch로 launch될 때도 init에서 등록되어 즉시 fire 수신 가능.
        registerHealthKitObservers()
        // UIKit appearance 차원의 tint 설정 — SwiftUI .tint() propagation이 sheet 깊은 곳에서 풀려
        // 시스템 blue로 fallback되는 회귀 보강. UIWindow.tintColor는 모든 UIView descendant에 propagate.
        applyTintAppearance()
    }

    /// 사용자 tint preset을 UIKit appearance에 반영. init + tint 변경 시 호출.
    /// 한 번 적용 후 새로 생성되는 UIView/UIKit-bridge component (DatePicker, NavigationStack toolbar 등)에 모두 propagate.
    private func applyTintAppearance() {
        let color = UIColor((TintPreset(rawValue: tintPresetRaw) ?? .blue).color)
        UIView.appearance().tintColor = color
        UIWindow.appearance().tintColor = color
        // 이미 생성된 window들도 즉시 갱신 (런타임 preset 변경 케이스 대응).
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.tintColor = color
            }
        }
    }

    /// 4-source HK observer 일괄 등록. handler에서 source별 active 항목 fetch → 조건부 update.
    /// 권한 거부 source는 enableBackgroundDelivery 실패하지만 observer 등록 자체는 무해.
    /// 사용자가 권한 허용하면 다음 launch에 자동 활성.
    private func registerHealthKitObservers() {
        let service = HealthKitService.shared
        guard service.isAvailable else { return }
        for source in [ActivitySourceType.steps, .distance, .calories, .flights] {
            service.startBackgroundObservation(for: source) { completion in
                Task { @MainActor in
                    await Item.handleHealthKitBackgroundFire(for: source) {
                        completion()
                    }
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingShown {
                    RootView()
                        .environment(\.managedObjectContext, persistence.viewContext)
                } else {
                    OnboardingView { onboardingShown = true }
                }
            }
            .tint(tintColor)
            .preferredColorScheme(colorScheme)
            // tintPreset 런타임 변경 (Settings에서 색 선택) 시 UIKit appearance 즉시 갱신.
            .onChange(of: tintPresetRaw) { _, _ in
                applyTintAppearance()
            }
        }
    }
}
