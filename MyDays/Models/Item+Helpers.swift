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

    var itemStartTimeOfDay: TimeOfDay {
        get { TimeOfDay(rawValue: startTimeOfDay) ?? .none }
        set { startTimeOfDay = newValue.rawValue }
    }

    var itemDueTimeOfDay: TimeOfDay {
        get { TimeOfDay(rawValue: dueTimeOfDay) ?? .none }
        set { dueTimeOfDay = newValue.rawValue }
    }

    func daysUntilDue(referenceDate: Date = Date()) -> Int? {
        guard let due = dueDate else { return nil }
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: referenceDate)
        let to = calendar.startOfDay(for: due)
        return calendar.dateComponents([.day], from: from, to: to).day
    }

    func isOverdue(referenceDate: Date = Date()) -> Bool {
        guard recurrenceRule == nil else { return false }
        guard itemStatus == .pending, let days = daysUntilDue(referenceDate: referenceDate) else { return false }
        return days < 0
    }

    // MARK: - Routine helpers

    func isCompletedForDate(_ date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        let completions = (self.completions as? Set<RoutineCompletion>) ?? []
        return completions.contains { c in
            guard c.done, let d = c.date else { return false }
            return calendar.isDate(d, inSameDayAs: day)
        }
    }

    func daysUntilNextOccurrence(referenceDate: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let rule = recurrenceRule else { return nil }
        guard let next = rule.nextOccurrence(after: referenceDate, startDate: startDate, endDate: dueDate, calendar: calendar) else {
            return nil
        }
        let today = calendar.startOfDay(for: referenceDate)
        return calendar.dateComponents([.day], from: today, to: next).day
    }

    func currentStreak(referenceDate: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let rule = recurrenceRule else { return 0 }
        let completions = (self.completions as? Set<RoutineCompletion>) ?? []
        let doneDates = Set(completions.compactMap { c -> Date? in
            guard c.done, let d = c.date else { return nil }
            return calendar.startOfDay(for: d)
        })

        var streak = 0
        var day = calendar.startOfDay(for: referenceDate)
        var safety = 365
        while safety > 0 {
            if rule.occurs(on: day, startDate: startDate, endDate: dueDate) {
                if doneDates.contains(day) {
                    streak += 1
                } else if !calendar.isDate(day, inSameDayAs: referenceDate) {
                    break
                }
            }
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
            safety -= 1
        }
        return streak
    }

    /// dueDate가 지난 routine을 자동으로 done 처리.
    static func completeExpiredRoutines(in context: NSManagedObjectContext, now: Date = Date()) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let request: NSFetchRequest<Item> = Item.fetchRequest()
        request.predicate = NSPredicate(
            format: "recurrenceRule != nil AND status == 0 AND dueDate != nil AND dueDate < %@",
            today as NSDate
        )
        do {
            let expired = try context.fetch(request)
            guard !expired.isEmpty else { return }
            for item in expired {
                item.itemStatus = .done
                item.completedAt = now
                item.updatedAt = now
                ItemEvent.log(.completed, on: item, in: context)
            }
            try context.save()
        } catch {
            assertionFailure("completeExpiredRoutines failed: \(error)")
        }
    }

    @discardableResult
    static func make(
        in context: NSManagedObjectContext,
        kind: ItemKind = .todo,
        title: String,
        priority: Priority = .none
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
