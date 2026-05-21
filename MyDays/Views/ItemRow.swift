import CoreData
import SwiftUI

struct ItemRow: View {

    @ObservedObject var item: Item
    @Environment(\.managedObjectContext) private var context

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggleDone) {
                Image(systemName: item.itemStatus == .done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.itemStatus == .done ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title ?? "")
                        .foregroundStyle(item.itemStatus == .done ? .secondary : .primary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if let dueLabel = dueDayLabel {
                        Text(dueLabel)
                            .font(.caption)
                            .foregroundStyle(item.isOverdue ? .red : .secondary)
                            .layoutPriority(1)
                    }
                }

                if item.itemPriority != .none && item.itemPriority != .medium {
                    Text(item.itemPriority.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(priorityColor.opacity(0.15))
                        .foregroundStyle(priorityColor)
                        .clipShape(Capsule())
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var dueDayLabel: String? {
        guard let days = item.daysUntilDue else { return nil }
        switch days {
        case 0: return "D-day"
        case let d where d > 0: return "D-\(d)"
        default: return "D+\(-days)"
        }
    }

    private var priorityColor: Color {
        switch item.itemPriority {
        case .high: return .red
        case .low:  return .blue
        default:    return .secondary
        }
    }

    private func toggleDone() {
        let now = Date()
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
}
