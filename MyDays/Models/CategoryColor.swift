import SwiftUI

// MARK: - CategoryColor
//
// Category 전용 8색 팔레트. 앱 tint(TintPreset)와는 별도 — 카테고리는 한눈에 구별이 잘 되는
// 채도 높은 8색 사용. iOS system color 기반.
//
// Category.colorHex 필드에 rawValue 저장 (예: "red"). 렌더 시 `CategoryColor(rawValue:)?.color`로 변환.

enum CategoryColor: String, CaseIterable, Identifiable {
    // 3번째 슬롯 hue 변경 이력:
    // - systemYellow(#FFCC00): light mode 텍스트 contrast 낮음
    // - mustard(#C9A227): brown(#A2845E)과 earth-tone 충돌
    // - **현재: indigo(#5856D6)** — blue/purple 사이 빈 영역, 다른 색과 명확 구분
    // case 이름 .yellow 유지 — rawValue도 "yellow"라 기존 DB row(colorHex="yellow") 자동 매핑.
    case red, orange, yellow, green, teal, blue, purple, brown

    var id: String { rawValue }

    /// iOS 표준 system color 기반 — 8색이 채도/명도에서 명확히 구별됨.
    var color: Color {
        switch self {
        case .red:    return Color(red: 1.00, green: 0.23, blue: 0.19) // #FF3B30
        case .orange: return Color(red: 1.00, green: 0.58, blue: 0.00) // #FF9500
        case .yellow: return Color(red: 0.35, green: 0.34, blue: 0.84) // #5856D6 indigo (case 이름 legacy)
        case .green:  return Color(red: 0.18, green: 0.62, blue: 0.30) // #2E9F4D — systemGreen 채도↑/명도↓ 텍스트 contrast 개선
        case .teal:   return Color(red: 0.04, green: 0.44, blue: 0.50) // #0A707F — cyan 쪽 hue + 더 어두운 톤으로 contrast 강화
        case .blue:   return Color(red: 0.00, green: 0.48, blue: 1.00) // #007AFF
        case .purple: return Color(red: 0.69, green: 0.32, blue: 0.87) // #AF52DE
        case .brown:  return Color(red: 0.64, green: 0.52, blue: 0.37) // #A2845E
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .red:    return "category.color.red"
        case .orange: return "category.color.orange"
        case .yellow: return "category.color.yellow"
        case .green:  return "category.color.green"
        case .teal:   return "category.color.teal"
        case .blue:   return "category.color.blue"
        case .purple: return "category.color.purple"
        case .brown:  return "category.color.brown"
        }
    }

    /// 신규 카테고리 default 색.
    static var defaultColor: CategoryColor { .blue }
}
