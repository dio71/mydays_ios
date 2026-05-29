import SwiftUI

// MARK: - CategoryIcon
//
// Category에 할당 가능한 SF Symbol preset. 사용자가 picker에서 선택.
// Category.iconName 필드(String?)에 symbolName 저장. 미설정 시 fallback = `defaultIcon`.
//
// 정렬: 비슷한 종류끼리 인접. 업무/생산성 → 건강/뷰티 → 생활/식사 → 여가/여행 → 관계/SNS →
// 동물/자연 → 기타. picker는 6열 grid라 6/12/18... 행 분배가 시각적으로 자연스러움.

enum CategoryIcon: String, CaseIterable, Identifiable {
    // 업무·생산성
    case briefcase, document, folder, chart, email, call, meeting,
         computer, programming, research, hardhat
    // 건강·뷰티
    case figureRun, heart, hospital, beauty, hand
    // 생활·식사·장소
    case forkKnife, cart, cafe, house, pin
    // 여가·여행
    case book, gamecontroller, musicNote, soccer, camping, airplane
    // 관계·SNS
    case person2, sns
    // 동물·자연
    case pawprint, leaf, star
    // 기타
    case car, power, tag, hashtag

    var id: String { rawValue }

    /// 실제 SF Symbol 이름 — Image(systemName:)에 사용.
    var symbolName: String {
        switch self {
        // 업무·생산성
        case .briefcase:     return "briefcase"
        case .document:      return "doc.text"
        case .folder:        return "folder"
        case .chart:         return "chart.line.uptrend.xyaxis"
        case .email:         return "envelope"
        case .call:          return "phone"
        case .meeting:       return "bubble.left.and.bubble.right"
        case .computer:      return "laptopcomputer"
        // </> 모양 — chevron + slash chevron 조합.
        case .programming:   return "chevron.left.forwardslash.chevron.right"
        case .research:      return "flask"
        case .hardhat:       return "hammer"
        // 건강·뷰티
        case .figureRun:     return "figure.run"
        case .heart:         return "heart"
        case .hospital:      return "cross.case"
        case .beauty:        return "sparkles"
        case .hand:          return "hand.raised"
        // 생활·식사·장소
        case .forkKnife:     return "fork.knife"
        case .cart:          return "cart"
        case .cafe:          return "cup.and.saucer"
        case .house:         return "house"
        case .pin:           return "mappin.and.ellipse"
        // 여가·여행
        case .book:          return "book.closed"
        case .gamecontroller: return "gamecontroller"
        case .musicNote:     return "music.note"
        case .soccer:        return "soccerball"
        case .camping:       return "tent"
        case .airplane:      return "airplane"
        // 관계·SNS
        case .person2:       return "person.2"
        case .sns:           return "at"
        // 동물·자연
        case .pawprint:      return "pawprint.fill"
        case .leaf:          return "leaf"
        case .star:          return "star"
        // 기타
        case .car:           return "car"
        case .power:         return "power"
        case .tag:           return "tag"
        // SF Symbol "number" = # 모양.
        case .hashtag:       return "number"
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
