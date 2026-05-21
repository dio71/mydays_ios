import CoreData
import SwiftUI

struct ActivityLogView: View {

    @FetchRequest(
        sortDescriptors: [SortDescriptor(\ItemEvent.timestamp, order: .reverse)],
        animation: .default
    )
    private var events: FetchedResults<ItemEvent>

    var body: some View {
        List {
            if events.isEmpty {
                Text("activity_log.empty")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(events, id: \.objectID) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: icon(for: event.itemAction))
                            .foregroundStyle(color(for: event.itemAction))
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: eventTitle(event))
                                .font(.subheadline)
                            Text(event.itemAction.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(verbatim: formattedDate(event.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("activity_log.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func eventTitle(_ event: ItemEvent) -> String {
        if let title = event.itemTitle, !title.isEmpty {
            return title
        }
        return String(localized: "activity_log.untitled")
    }

    private func icon(for action: ItemAction) -> String {
        switch action {
        case .created:     return "plus.circle"
        case .updated:     return "pencil.circle"
        case .completed:   return "checkmark.circle.fill"
        case .uncompleted: return "arrow.uturn.backward.circle"
        case .cancelled:   return "xmark.circle"
        case .restored:    return "arrow.clockwise.circle"
        case .deleted:     return "trash.circle"
        case .failed:      return "flag.slash.circle"
        }
    }

    private func color(for action: ItemAction) -> Color {
        switch action {
        case .completed: return .green
        case .deleted:   return .red
        case .cancelled: return .orange
        case .failed:    return .orange
        default:         return .secondary
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        if Calendar.current.isDateInToday(date) {
            formatter.setLocalizedDateFormatFromTemplate("HHmm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("Md HHmm")
        }
        return formatter.string(from: date)
    }
}

#Preview {
    NavigationStack { ActivityLogView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
