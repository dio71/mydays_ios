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
