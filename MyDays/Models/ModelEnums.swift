import Foundation

enum ItemKind: Int16, CaseIterable {
    case todo = 0
    case notTodo = 1   // 절제 — 시간 기반, 사용자 포기 액션 없으면 자동 완료
    case activity = 2  // 활동 — 수치 기반 목표, valueRecorded >= target이면 자동 완료
    case focus = 3     // 집중 — 타이머 기반 (시작/일시정지/누적). Phase D 예정
    case habit = 4     // 습관 — 매일/매주 체크 (routine Todo와 동작 같지만 목표 정체성)

    /// 사용자 노출 명칭. enum case명은 내부, 표시엔 항상 displayName 사용.
    var displayName: String {
        switch self {
        case .todo:     return String(localized: "item_kind.todo")
        case .notTodo:  return String(localized: "item_kind.not_todo")
        case .activity: return String(localized: "item_kind.activity")
        case .focus:    return String(localized: "item_kind.focus")
        case .habit:    return String(localized: "item_kind.habit")
        }
    }

    /// 목표(절제 + 활동 + 집중 + 습관)는 같은 섹션·같은 입력 패턴(icon+color 사용자 지정, 카테고리 미사용).
    var isGoal: Bool { self != .todo }

    /// 목표 sub-picker용 SF Symbol — 입력 폼 type 선택 chip 아이콘.
    /// 습관은 trailing 체크 버튼(square)과 동일 스타일 — Todo의 checkmark.circle과 구분.
    /// 4-type 모두 GoalIcon의 대표 case와 매칭 (defaultGoalIcon).
    var goalTypeSymbolName: String {
        switch self {
        case .notTodo:  return "hand.raised.fill"
        case .activity: return "figure.run"
        case .focus:    return "hourglass.bottomhalf.filled"
        case .habit:    return "checkmark.square.fill"
        case .todo:     return "checkmark.circle"  // unused (목표 sub-picker만 사용)
        }
    }

    /// 입력 가능한 type인지. Phase D에서 focus 활성화.
    var isAvailableForInput: Bool { true }
}

/// 활동 목표의 측정 source.
/// - manual: 사용자가 값 직접 입력 (버튼 / 숫자 입력)
/// - steps: HealthKit 걸음수 자동 측정
/// - distance: HealthKit 거리 자동 측정 (미터 단위)
/// - calories: HealthKit 활동 에너지 자동 측정 (kcal)
/// - flights: HealthKit 계단 오른 층수 자동 측정 (count)
enum ActivitySourceType: Int16, CaseIterable {
    case manual = 0
    case steps = 1
    case distance = 2
    case calories = 3
    case flights = 4

    var displayName: String {
        switch self {
        case .manual:   return String(localized: "activity_source.manual")
        case .steps:    return String(localized: "activity_source.steps")
        case .distance: return String(localized: "activity_source.distance")
        case .calories: return String(localized: "activity_source.calories")
        case .flights:  return String(localized: "activity_source.flights")
        }
    }
}

enum Priority: Int16, CaseIterable {
    case none = 0
    case medium = 1
    case high = 2
    case low = 3

    var displayName: String {
        switch self {
        case .none:   return String(localized: "priority.none")
        case .high:   return String(localized: "priority.high")
        case .medium: return String(localized: "priority.medium")
        case .low:    return String(localized: "priority.low")
        }
    }

    static let pickerOrder: [Priority] = [.high, .medium, .low, .none]
}

enum Status: Int16, CaseIterable {
    case pending = 0
    case done = 1
    case deleted = 2
    case failed = 3
}

enum Frequency: Int16, CaseIterable {
    case daily = 0
    case weekly = 1
    case monthly = 2
    case weekdays = 3
    case weekend = 4
    case weeklyCount = 5
    case yearly = 6
}

enum ReminderAnchor: Int16, CaseIterable {
    case absolute = 0
    case start = 1
    case due = 2
}

enum TimeOfDay: Int16, CaseIterable {
    case none = 0
    case morning = 1
    case afternoon = 2
    case evening = 3

    var displayName: String {
        switch self {
        case .none:      return String(localized: "time_of_day.none")
        case .morning:   return String(localized: "time_of_day.morning")
        case .afternoon: return String(localized: "time_of_day.afternoon")
        case .evening:   return String(localized: "time_of_day.evening")
        }
    }

    /// Todo 알림 fire 시각 매핑 (wall-clock 시간).
    /// 오전 9 / 오후 14 / 저녁 19 / 미설정 9 (default).
    var defaultHour: Int {
        switch self {
        case .morning:   return 9
        case .afternoon: return 14
        case .evening:   return 19
        case .none:      return 9
        }
    }
}

enum ItemAction: Int16, CaseIterable {
    case created = 0
    case updated = 1
    case completed = 2
    case uncompleted = 3
    case cancelled = 4
    case restored = 5
    case deleted = 6
    case failed = 7

    var displayName: String {
        switch self {
        case .created:     return String(localized: "item_action.created")
        case .updated:     return String(localized: "item_action.updated")
        case .completed:   return String(localized: "item_action.completed")
        case .uncompleted: return String(localized: "item_action.uncompleted")
        case .cancelled:   return String(localized: "item_action.cancelled")
        case .restored:    return String(localized: "item_action.restored")
        case .deleted:     return String(localized: "item_action.deleted")
        case .failed:      return String(localized: "item_action.failed")
        }
    }
}
