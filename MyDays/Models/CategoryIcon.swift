import SwiftUI

// MARK: - CategoryIcon
//
// Category에 할당 가능한 SF Symbol preset 12개. 사용자가 picker에서 선택.
// Category.iconName 필드(String?)에 symbolName 저장. 미설정 시 fallback = `defaultIcon`.
//
// 색상은 TintPreset 8색 팔레트 재사용 — 앱 tint와 동일 톤으로 일관성. Category.colorHex 필드에
// TintPreset.rawValue(예: "coral") 저장. 렌더 시 `TintPreset(rawValue:)?.color`로 변환.

enum CategoryIcon: String, CaseIterable, Identifiable {
    case briefcase, book, figureRun, heart, house, airplane,
         forkKnife, cart, gamecontroller, person2, musicNote, tag,
         // 업무/프로젝트 진행 관련 추가.
         meeting, document, chart, email, call, folder

    var id: String { rawValue }

    /// 실제 SF Symbol 이름 — Image(systemName:)에 사용.
    var symbolName: String {
        switch self {
        case .briefcase:     return "briefcase"
        case .book:          return "book.closed"
        case .figureRun:     return "figure.run"
        case .heart:         return "heart"
        case .house:         return "house"
        case .airplane:      return "airplane"
        case .forkKnife:     return "fork.knife"
        case .cart:          return "cart"
        case .gamecontroller: return "gamecontroller"
        case .person2:       return "person.2"
        case .musicNote:     return "music.note"
        case .tag:           return "tag"
        // 업무 관련
        case .meeting:       return "bubble.left.and.bubble.right"
        case .document:      return "doc.text"
        case .chart:         return "chart.line.uptrend.xyaxis"
        case .email:         return "envelope"
        case .call:          return "phone"
        case .folder:        return "folder"
        }
    }

    /// 신규 카테고리 default — symbol 이름만 fallback에 사용.
    static var defaultIcon: CategoryIcon { .tag }

    /// 저장된 symbolName 으로부터 enum 복원. 미매칭 시 default.
    static func fromSymbolName(_ name: String?) -> CategoryIcon {
        guard let name else { return defaultIcon }
        return allCases.first { $0.symbolName == name } ?? defaultIcon
    }
}
