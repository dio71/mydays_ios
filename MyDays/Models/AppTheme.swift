import SwiftUI

// MARK: - App-wide theme settings
//
// Tint(accent) preset + appearance mode(light/dark) — 사용자가 Settings에서 선택.
// @AppStorage 키로 UserDefaults에 저장돼 앱 재실행 후에도 유지.
// MyDaysApp 루트에서 `.tint()` + `.preferredColorScheme()` 적용 → 자식 view들에 propagate.
//
// 위젯 process는 별도 UserDefaults 도메인 — 추후 App Group으로 공유하려면 별도 작업.
// 현재 Phase 1은 main app만 적용.

/// 앱 accent 색 preset. 사용자가 Settings에서 8가지 중 선택. 기본=blue.
/// `Color.accentColor`는 SwiftUI 환경값을 읽으므로 root `.tint()`에 전달하면 자동 propagate.
/// 색상 후보는 디자이너 큐레이션 — 따뜻한 톤 위주.
enum TintPreset: String, CaseIterable, Identifiable {
    case blue, coral, peach, mustard, sage, slate, forest, wine

    var id: String { rawValue }

    /// SwiftUI Color — `.tint()`에 전달.
    var color: Color {
        switch self {
        case .blue:    return .blue
        case .coral:   return Color(red: 0xE4/255, green: 0x7A/255, blue: 0x66/255)
        case .peach:   return Color(red: 0xEF/255, green: 0x97/255, blue: 0x6B/255)
        case .mustard: return Color(red: 0xDA/255, green: 0xA5/255, blue: 0x22/255)
        case .sage:    return Color(red: 0x8A/255, green: 0xAA/255, blue: 0x56/255)
        case .slate:   return Color(red: 0x5C/255, green: 0x7C/255, blue: 0x95/255)
        case .forest:  return Color(red: 0x2A/255, green: 0x60/255, blue: 0x48/255)
        case .wine:    return Color(red: 0x82/255, green: 0x38/255, blue: 0x53/255)
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .blue:    return "settings.tint.blue"
        case .coral:   return "settings.tint.coral"
        case .peach:   return "settings.tint.peach"
        case .mustard: return "settings.tint.mustard"
        case .sage:    return "settings.tint.sage"
        case .slate:   return "settings.tint.slate"
        case .forest:  return "settings.tint.forest"
        case .wine:    return "settings.tint.wine"
        }
    }
}

/// 외관 모드 — 시스템 따라감(default) / 강제 light / 강제 dark.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    /// UI 표시 순서 — Light, Dark, System.
    static var displayOrder: [AppearanceMode] { [.light, .dark, .system] }

    /// `.preferredColorScheme()`에 전달. nil이면 시스템 설정 따름.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .system: return "settings.appearance.system"
        case .light:  return "settings.appearance.light"
        case .dark:   return "settings.appearance.dark"
        }
    }
}

/// `@AppStorage` 키 상수 — 중앙 관리.
enum AppThemeKey {
    static let tintPreset = "app.tintPreset"
    static let appearanceMode = "app.appearanceMode"
}

/// UI 상태 영속화 키. 탭별 toggle/mode 등 — UserDefaults.standard에 저장 (App Group 공유 불필요).
/// 카테고리 필터(filterCategoryID)는 저장 X — 매 launch마다 "모두"로 초기화 (사용자 결정).
enum UIStateKey {
    static let todayViewMode = "ui.todayView.viewMode"           // day/month
    static let todayShowCompleted = "ui.todayView.showCompleted" // 전체/미완료
    static let listShowCompleted = "ui.listView.showCompleted"
    static let listGroupByCategory = "ui.listView.groupByCategory"
    static let archiveShowCompleted = "ui.archiveView.showCompleted"
    static let archiveGroupByCategory = "ui.archiveView.groupByCategory"
}

// MARK: - App Group 공유 UserDefaults
//
// App 본체와 Widget Extension이 같은 entitlement(`group.io.snapplay.MyDays`)로 공유하는 suite.
// 위젯 process는 본체와 별도 UserDefaults라 standard로 저장하면 위젯에서 읽지 못함 →
// 모든 사용자 테마 설정(tintPreset / appearanceMode)을 이 suite에 저장하면 위젯도 동일 값 사용.
//
// 모든 `@AppStorage(...)` 사용처는 `store: .appShared`로 지정해야 함 (본체·위젯 일관).

extension UserDefaults {
    static let appShared: UserDefaults = {
        UserDefaults(suiteName: "group.io.snapplay.MyDays") ?? .standard
    }()
}

/// Widget에서 사용할 사용자 tint color 읽기 helper.
/// SwiftUI `@AppStorage`를 ViewModifier 안에서 안전하게 쓰기 까다로워 정적 lookup 우선.
extension TintPreset {
    /// 공유 UserDefaults에서 현재 사용자 tint preset을 읽어 SwiftUI Color로 반환.
    /// 값 없으면 default `.blue`.
    static var currentColor: Color {
        let raw = UserDefaults.appShared.string(forKey: AppThemeKey.tintPreset)
                  ?? TintPreset.blue.rawValue
        return (TintPreset(rawValue: raw) ?? .blue).color
    }
}

// MARK: - App tint propagation helper
//
// 루트 `.tint(tintColor)`는 대부분 자식에 전달되지만, sheet 안 NavigationStack /
// .graphical DatePicker 같은 UIKit-bridged view에서 시스템 기본(파랑)으로 fallback되는 경우가 있다.
// 그 시점에 form 안만 파랑으로 보이는 현상이 보고됨. 해당 sheet/view 루트에 `.appTint()` 명시
// 재적용으로 안전 보장.

private struct AppTintModifier: ViewModifier {
    @AppStorage(AppThemeKey.tintPreset, store: .appShared)
    private var tintPresetRaw: String = TintPreset.blue.rawValue

    private var tintColor: Color {
        (TintPreset(rawValue: tintPresetRaw) ?? .blue).color
    }

    func body(content: Content) -> some View {
        content.tint(tintColor)
    }
}

extension View {
    /// 사용자가 Settings에서 고른 앱 tint를 강제 재적용. sheet root / UIKit bridge용.
    func appTint() -> some View {
        modifier(AppTintModifier())
    }

    /// iPad/regular size class에서 본문 폭 cap — 가독성을 위해 너무 넓어지지 않게.
    /// compact(iPhone)은 영향 X.
    func iPadContentWidth(_ maxWidth: CGFloat = 700) -> some View {
        modifier(IPadContentWidthModifier(maxWidth: maxWidth))
    }
}

private struct IPadContentWidthModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSize
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        if hSize == .regular {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}
