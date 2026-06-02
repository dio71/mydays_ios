import SwiftUI

// MARK: - GoalIcon
//
// 목표(절제·활동·집중·습관)에 할당 가능한 24개 아이콘 preset.
// Item.iconName 필드(String?)에 **rawValue**(semantic identifier) 저장.
// 예: "run", "water", "fast" — SF Symbol 이름이 아닌 추상 식별자.
//
// 크로스플랫폼 호환:
// - iOS: GoalIcon.symbolName이 SF Symbol 이름으로 매핑 (`figure.run` 등)
// - Android (이후): 같은 enum 정의 + Material Icon/drawable mapping
// - DB 컬럼 값은 양 플랫폼 공통 — visual asset만 플랫폼별 분기.
//
// CategoryIcon은 현재 SF Symbol 이름 직접 저장 (iOS 전용). 향후 동일 패턴으로 마이그 필요 (별도 phase).
//
// 정렬: 목표 유형 대표 4개(절제/활동/집중/습관) 맨 앞 → 절제 → 운동 → 활동·개인 순.
// 6열 grid 기준 4행. 같은 그룹은 인접 배치해 사용자가 시각 분류 쉽게.

enum GoalIcon: String, CaseIterable, Identifiable {
    // 목표 유형 대표 (4) — ItemKind.goalTypeSymbolName과 매칭. type 선택 시 default GoalIcon.
    case abstain    // 절제 대표
    case run        // 활동 대표 (figure.run — 달리기로도 쓰임)
    case focus      // 집중 대표
    case habit      // 습관 대표

    // 절제 (3)
    case fast       // 단식
    case alcohol    // 금주
    case caffeine   // 카페인 절제

    // 운동 (7)
    case walk       // 걷기
    case jumprope   // 줄넘기
    case cycle      // 사이클
    case exercise   // 운동(웨이트)
    case stretch    // 스트레칭
    case baseball   // 야구
    case soccer     // 축구

    // 활동·개인 (10)
    case move       // 이동하기
    case meditation // 명상
    case read       // 독서
    case study      // 공부
    case pill       // 약 복용
    case water      // 물 마시기
    case shower     // 샤워
    case sleep      // 수면
    case dogwalk    // 강아지 산책
    case cart       // 장보기

    var id: String { rawValue }

    /// 실제 SF Symbol 이름 — `Image(systemName:)`에 사용. DB 저장 X.
    /// 모두 iOS 17+ 지원 symbol.
    var symbolName: String {
        switch self {
        case .abstain:    return "hand.raised.fill"
        case .run:        return "figure.run"
        case .focus:      return "hourglass.bottomhalf.filled"
        case .habit:      return "checkmark.square.fill"
        case .fast:       return "fork.knife"
        case .alcohol:    return "wineglass.fill"
        case .caffeine:   return "mug.fill"
        case .walk:       return "figure.walk"
        case .jumprope:   return "figure.jumprope"
        case .cycle:      return "figure.outdoor.cycle"
        case .exercise:   return "dumbbell.fill"
        case .stretch:    return "figure.cooldown"
        case .baseball:   return "baseball.fill"
        case .soccer:     return "soccerball"
        case .move:       return "point.bottomleft.forward.to.arrow.triangle.scurvepath.fill"
        case .meditation: return "figure.mind.and.body"
        case .read:       return "book.fill"
        case .study:      return "graduationcap.fill"
        case .pill:       return "pill.fill"
        case .water:      return "drop.fill"
        case .shower:     return "shower.handheld.fill"
        case .sleep:      return "moon.stars.fill"
        case .dogwalk:    return "dog.fill"
        case .cart:       return "cart.fill"
        }
    }

    /// 저장된 rawValue로부터 enum 복원. 미매칭/nil → nil (사용자 선택 강제).
    static func from(_ name: String?) -> GoalIcon? {
        guard let name else { return nil }
        return GoalIcon(rawValue: name)
    }
}

extension ItemKind {
    /// type 선택 시 자동 set할 GoalIcon — `goalTypeSymbolName`과 동일 SF Symbol.
    /// AddItemView가 신규 + GoalIcon 미선택 상태일 때만 적용. Todo는 nil.
    /// (이 extension은 GoalIcon.swift에 둠 — ModelEnums.swift는 widget target에도 포함되지만
    /// GoalIcon.swift는 main app/widget 모두 포함이라 GoalIcon 참조 가능. 향후 멤버십 분리 시 주의.)
    var defaultGoalIcon: GoalIcon? {
        switch self {
        case .notTodo:  return .abstain
        case .activity: return .run
        case .focus:    return .focus
        case .habit:    return .habit
        case .todo:     return nil
        }
    }
}
