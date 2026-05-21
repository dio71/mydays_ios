import Foundation

enum ItemKind: Int16, CaseIterable {
    case todo = 0
    case notTodo = 1
}

enum Priority: Int16, CaseIterable {
    case none = 0
    case medium = 1
    case high = 2
    case low = 3

    var displayName: String {
        switch self {
        case .none:   return "없음"
        case .high:   return "상"
        case .medium: return "중"
        case .low:    return "하"
        }
    }

    static let pickerOrder: [Priority] = [.high, .medium, .low, .none]
}

enum Status: Int16, CaseIterable {
    case pending = 0
    case done = 1
    case cancelled = 2
    case failed = 3
}

enum Frequency: Int16, CaseIterable {
    case daily = 0
    case weekly = 1
    case monthly = 2
    case weekdays = 3
    case weekend = 4
    case weeklyCount = 5
}

enum ReminderAnchor: Int16, CaseIterable {
    case absolute = 0
    case start = 1
    case due = 2
}

enum ItemAction: Int16, CaseIterable {
    case created = 0
    case updated = 1
    case completed = 2
    case uncompleted = 3
    case cancelled = 4
    case restored = 5
    case deleted = 6

    var displayName: String {
        switch self {
        case .created:     return "생성"
        case .updated:     return "수정"
        case .completed:   return "완료"
        case .uncompleted: return "완료 취소"
        case .cancelled:   return "취소"
        case .restored:    return "복원"
        case .deleted:     return "삭제"
        }
    }
}
