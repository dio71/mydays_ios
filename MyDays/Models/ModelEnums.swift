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
