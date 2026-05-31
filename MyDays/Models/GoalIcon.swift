import SwiftUI

// MARK: - GoalIcon
//
// 목표(절제·활동)에 할당 가능한 12개 아이콘 preset.
// Item.iconName 필드(String?)에 **rawValue**(semantic identifier) 저장.
// 예: "run", "water", "fast" — SF Symbol 이름이 아닌 추상 식별자.
//
// 크로스플랫폼 호환:
// - iOS: GoalIcon.symbolName이 SF Symbol 이름으로 매핑 (`figure.run` 등)
// - Android (이후): 같은 enum 정의 + Material Icon/drawable mapping
// - DB 컬럼 값은 양 플랫폼 공통 — visual asset만 플랫폼별 분기.
//
// CategoryIcon은 현재 SF Symbol 이름 직접 저장 (iOS 전용). 향후 동일 패턴으로 마이그 필요 (별도 phase).

enum GoalIcon: String, CaseIterable, Identifiable {
    // 절제 (6)
    case fast       // 단식
    case alcohol    // 금주
    case smoke      // 금연
    case caffeine   // 카페인 절제
    case sweet      // 단것 절제
    case phone      // 폰 사용 절제

    // 활동 (6)
    case run        // 달리기
    case walk       // 걷기
    case exercise   // 운동
    case water      // 물 마시기
    case meditation // 명상
    case read       // 독서

    var id: String { rawValue }

    /// 실제 SF Symbol 이름 — `Image(systemName:)`에 사용. DB 저장 X.
    /// 모두 iOS 17+ 지원 symbol.
    var symbolName: String {
        switch self {
        case .fast:       return "fork.knife"
        case .alcohol:    return "wineglass"
        case .smoke:      return "smoke.fill"
        case .caffeine:   return "cup.and.saucer.fill"
        case .sweet:      return "birthday.cake.fill"
        case .phone:      return "iphone"
        case .run:        return "figure.run"
        case .walk:       return "figure.walk"
        case .exercise:   return "dumbbell.fill"
        case .water:      return "drop.fill"
        case .meditation: return "figure.mind.and.body"
        case .read:       return "book.fill"
        }
    }

    /// 저장된 rawValue로부터 enum 복원. 미매칭/nil → nil (사용자 선택 강제).
    static func from(_ name: String?) -> GoalIcon? {
        guard let name else { return nil }
        return GoalIcon(rawValue: name)
    }
}
