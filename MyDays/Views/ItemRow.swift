import CoreData
import SwiftUI

struct ItemRow: View {

    @ObservedObject var item: Item
    var referenceDate: Date = Date()
    var showRoutineDday: Bool = false
    var routineCheckable: Bool = true
    @Environment(\.managedObjectContext) private var context

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leadingControl
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title ?? "")
                        .foregroundStyle(isCompletedForDate ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let todLabel = timeOfDayLabel {
                        Text(todLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                    }
                    if let dueLabel = dueDayLabel {
                        Text(dueLabel)
                            .font(.caption)
                            .foregroundStyle(item.isOverdue(referenceDate: referenceDate) ? .red : .secondary)
                            .layoutPriority(1)
                    }
                }

                if let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if hasAnyStatusIcon {
                    statusIcons
                }
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - leading control

    @ViewBuilder
    private var leadingControl: some View {
        if isRoutine && !routineCheckable {
            Image(systemName: "repeat")
                .font(.title3)
                .foregroundStyle(.secondary)
        } else {
            Button(action: toggleDone) {
                Image(systemName: isCompletedForDate ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isCompletedForDate ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - completion

    private var isRoutine: Bool { item.recurrenceRule != nil }

    private var isCompletedForDate: Bool {
        if isRoutine {
            return item.isCompletedForDate(referenceDate)
        }
        return item.itemStatus == .done
    }

    private func toggleDone() {
        let now = Date()
        if isRoutine {
            toggleRoutineCompletion(now: now)
        } else {
            toggleStatusDone(now: now)
        }
    }

    private func toggleRoutineCompletion(now: Date) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: referenceDate)
        let completions = (item.completions as? Set<RoutineCompletion>) ?? []
        let existing = completions.first { c in
            guard let d = c.date else { return false }
            return calendar.isDate(d, inSameDayAs: day)
        }
        let action: ItemAction
        if let existing {
            context.delete(existing)
            action = .uncompleted
        } else {
            let comp = RoutineCompletion(context: context)
            comp.id = UUID()
            comp.date = day
            comp.done = true
            comp.item = item
            action = .completed
        }
        item.updatedAt = now
        ItemEvent.log(action, on: item, in: context)
        do {
            try context.save()
        } catch {
            assertionFailure("Routine toggle save failed: \(error)")
        }
    }

    private func toggleStatusDone(now: Date) {
        let action: ItemAction
        if item.itemStatus == .done {
            item.itemStatus = .pending
            item.completedAt = nil
            action = .uncompleted
        } else {
            item.itemStatus = .done
            item.completedAt = now
            action = .completed
        }
        item.updatedAt = now
        ItemEvent.log(action, on: item, in: context)
        do {
            try context.save()
        } catch {
            assertionFailure("Toggle save failed: \(error)")
        }
    }

    // MARK: - status icons

    private var hasAnyStatusIcon: Bool {
        if item.itemPriority != .none { return true }
        if let comment = item.comment, !comment.isEmpty { return true }
        if streakValue != nil { return true }
        return false
    }

    @ViewBuilder
    private var statusIcons: some View {
        HStack(spacing: 8) {
            if item.itemPriority != .none {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(flagColor(for: item.itemPriority))
            }
            if let comment = item.comment, !comment.isEmpty {
                Image(systemName: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let streak = streakValue {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                    Text(verbatim: "\(streak)")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var streakValue: Int? {
        guard isRoutine else { return nil }
        let s = item.currentStreak(referenceDate: referenceDate)
        return s > 0 ? s : nil
    }

    private func flagColor(for priority: Priority) -> Color {
        switch priority {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .blue
        case .none:   return .secondary
        }
    }

    private var dueDayLabel: String? {
        if isRoutine {
            guard showRoutineDday,
                  let days = item.daysUntilNextOccurrence(referenceDate: referenceDate)
            else { return nil }
            if days == 0 { return "D-day" }
            if days > 0  { return "D-\(days)" }
            return nil
        }
        guard let days = item.daysUntilDue(referenceDate: referenceDate) else { return nil }
        switch days {
        case 0: return "D-day"
        case let d where d > 0: return "D-\(d)"
        default: return "D+\(-days)"
        }
    }

    private var timeOfDayLabel: String? {
        let due = item.itemDueTimeOfDay
        return due == .none ? nil : due.displayName
    }

}
