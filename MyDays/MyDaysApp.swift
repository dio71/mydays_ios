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
    /// iOS 26 floating tab bar는 `tintColor`만으로 selected item 색이 갱신 안 되는 경우가 있어
    /// `selectedItemTintColor` + `UITabBarAppearance` (item appearance) 모두 갱신.
    /// 신규 생성 default + 기존 인스턴스 즉시 갱신 둘 다 처리.
    private func applyTintAppearance() {
        let color = UIColor((TintPreset(rawValue: tintPresetRaw) ?? .blue).color)
        UIView.appearance().tintColor = color
        UIWindow.appearance().tintColor = color
        UINavigationBar.appearance().tintColor = color

        // 신규 생성 UITabBar에 standard + scrollEdge appearance 설정 — selected icon/text tint 명시.
        let tabAppearance = Self.makeTabBarAppearance(tintColor: color)
        UITabBar.appearance().tintColor = color
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        // 이미 생성된 window + 그 안 모든 tab bar / nav bar 인스턴스 즉시 갱신.
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.tintColor = color
                Self.refreshTintInSubviews(window, color: color, tabAppearance: tabAppearance)
            }
        }
    }

    /// UITabBarAppearance — selected/normal item 색상 명시 설정.
    /// iOS 26 tab bar는 단순 tintColor 대신 이 appearance를 통해 selected 상태 색을 결정하는 경우가 있어
    /// 두 경로 모두 갱신해야 즉시 반영 보장.
    private static func makeTabBarAppearance(tintColor: UIColor) -> UITabBarAppearance {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        let item = UITabBarItemAppearance()
        item.selected.iconColor = tintColor
        item.selected.titleTextAttributes = [.foregroundColor: tintColor]
        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item
        return appearance
    }

    /// view tree 재귀 walk — UITabBar / UINavigationBar 인스턴스에 명시적으로 tintColor + appearance 갱신.
    /// 추가로 UITabBar 내부 모든 UIImageView 의 tintColor도 직접 갱신 — iOS 26 floating tab bar의 SF Symbol
    /// 아이콘이 UITabBarItemAppearance.iconColor를 무시하고 본인 UIImageView의 tintColor를 캐시하는 케이스 대응.
    private static func refreshTintInSubviews(_ view: UIView, color: UIColor, tabAppearance: UITabBarAppearance) {
        if let tabBar = view as? UITabBar {
            tabBar.tintColor = color
            tabBar.standardAppearance = tabAppearance
            tabBar.scrollEdgeAppearance = tabAppearance
            // 내부 모든 UIImageView 아이콘에도 tint 직접 적용.
            forceIconTint(in: tabBar, color: color)
            tabBar.setNeedsLayout()
            tabBar.setNeedsDisplay()
        } else if let navBar = view as? UINavigationBar {
            navBar.tintColor = color
            navBar.setNeedsLayout()
        }
        for subview in view.subviews {
            refreshTintInSubviews(subview, color: color, tabAppearance: tabAppearance)
        }
    }

    /// UITabBar 내부 모든 UIImageView 의 tintColor를 직접 갱신.
    /// 일부 iOS 버전에서 selected item 아이콘은 자체 캐시된 tintColor를 갖고 있어 명시 갱신해야 즉시 반영.
    private static func forceIconTint(in view: UIView, color: UIColor) {
        if let imageView = view as? UIImageView {
            imageView.tintColor = color
        }
        for subview in view.subviews {
            forceIconTint(in: subview, color: color)
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
