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
                Text("아직 활동이 없습니다")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(events, id: \.objectID) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: icon(for: event.itemAction))
                            .foregroundStyle(color(for: event.itemAction))
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.itemTitle?.isEmpty == false ? event.itemTitle! : "(제목 없음)")
                                .font(.subheadline)
                            Text(event.itemAction.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(formattedDate(event.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("활동 로그")
        .navigationBarTitleDisplayMode(.inline)
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
        }
    }

    private func color(for action: ItemAction) -> Color {
        switch action {
        case .completed: return .green
        case .deleted:   return .red
        case .cancelled: return .orange
        default:         return .secondary
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "M/d HH:mm"
        }
        return formatter.string(from: date)
    }
}

#Preview {
    NavigationStack { ActivityLogView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
