import CoreData
import Foundation

extension Item {

    var itemKind: ItemKind {
        get { ItemKind(rawValue: kind) ?? .todo }
        set { kind = newValue.rawValue }
    }

    var itemPriority: Priority {
        get { Priority(rawValue: priority) ?? .medium }
        set { priority = newValue.rawValue }
    }

    var itemStatus: Status {
        get { Status(rawValue: status) ?? .pending }
        set { status = newValue.rawValue }
    }

    var daysUntilDue: Int? {
        guard let due = dueDate else { return nil }
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: Date())
        let to = calendar.startOfDay(for: due)
        return calendar.dateComponents([.day], from: from, to: to).day
    }

    var isOverdue: Bool {
        guard itemStatus == .pending, let days = daysUntilDue else { return false }
        return days < 0
    }

    @discardableResult
    static func make(
        in context: NSManagedObjectContext,
        kind: ItemKind = .todo,
        title: String,
        priority: Priority = .medium
    ) -> Item {
        let now = Date()
        let item = Item(context: context)
        item.id = UUID()
        item.title = title
        item.itemKind = kind
        item.itemPriority = priority
        item.itemStatus = .pending
        item.createdAt = now
        item.updatedAt = now
        return item
    }
}
