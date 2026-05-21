import CoreData
import SwiftUI

struct TodayView: View {

    @State private var displayedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var sheet: ItemSheetMode?

    var body: some View {
        TodayList(date: displayedDate, sheet: $sheet)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { shiftDay(-1) } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                if isFarFuture {
                    if #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .topBarLeading)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: jumpToToday) {
                            Text("nav.jump_home")
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(navigationTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize()
                }
                if isFarPast {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: jumpToToday) {
                            Text("nav.jump_home")
                        }
                    }
                    if #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { shiftDay(1) } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    sheet = .new(baseDate: displayedDate)
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.accentColor))
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                }
                .padding(20)
            }
            .sheet(item: $sheet) { mode in
                switch mode {
                case .new(let baseDate):
                    AddItemView(baseDate: baseDate)
                case .edit(let item):
                    AddItemView(editing: item)
                }
            }
    }

    private func shiftDay(_ value: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: value, to: displayedDate) {
            displayedDate = next
        }
    }

    private func jumpToToday() {
        displayedDate = Calendar.current.startOfDay(for: Date())
    }

    private var daysFromToday: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.dateComponents([.day], from: today, to: displayedDate).day ?? 0
    }

    private var isFarPast: Bool { daysFromToday < -1 }
    private var isFarFuture: Bool { daysFromToday > 1 }

    private var navigationTitle: String {
        switch daysFromToday {
        case 0:  return String(localized: "today.nav.today")
        case 1:  return String(localized: "today.nav.tomorrow")
        case -1: return String(localized: "today.nav.yesterday")
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.setLocalizedDateFormatFromTemplate("MMMd EEE")
            return formatter.string(from: displayedDate)
        }
    }
}

struct TodayList: View {

    let date: Date
    @Binding var sheet: ItemSheetMode?
    @Environment(\.scenePhase) private var scenePhase
    @State private var referenceDate = Date()

    @FetchRequest var dueItems: FetchedResults<Item>
    @FetchRequest var inProgressItems: FetchedResults<Item>
    @FetchRequest var startItems: FetchedResults<Item>
    @FetchRequest var routineItems: FetchedResults<Item>

    init(date: Date, sheet: Binding<ItemSheetMode?>) {
        self.date = date
        self._sheet = sheet
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let sort = [SortDescriptor(\Item.priority, order: .reverse), SortDescriptor(\Item.createdAt)]

        _dueItems = FetchRequest(
            sortDescriptors: sort,
            predicate: NSPredicate(
                format: "dueDate >= %@ AND dueDate < %@ AND status == 0 AND recurrenceRule == nil",
                start as NSDate, end as NSDate
            ),
            animation: .default
        )
        _inProgressItems = FetchRequest(
            sortDescriptors: sort,
            predicate: NSPredicate(
                format: "startDate < %@ AND dueDate >= %@ AND status == 0 AND recurrenceRule == nil",
                start as NSDate, end as NSDate
            ),
            animation: .default
        )
        _startItems = FetchRequest(
            sortDescriptors: sort,
            predicate: NSPredicate(
                format: "startDate >= %@ AND startDate < %@ AND status == 0 AND (dueDate == nil OR dueDate >= %@) AND recurrenceRule == nil",
                start as NSDate, end as NSDate, end as NSDate
            ),
            animation: .default
        )
        _routineItems = FetchRequest(
            sortDescriptors: sort,
            predicate: NSPredicate(
                format: "recurrenceRule != nil AND status != 2"
            ),
            animation: .default
        )
    }

    private var routinesForDate: [Item] {
        let target = date
        return routineItems.filter { item in
            guard let rule = item.recurrenceRule else { return false }
            return rule.occurs(on: target, startDate: item.startDate, endDate: item.dueDate)
        }
    }

    var body: some View {
        List {
            Section("today.section.not_todo") {
                emptyRow("today.empty.not_todo")
            }

            Section("today.section.due") {
                if dueItems.isEmpty {
                    emptyRow("today.empty.due")
                } else {
                    ForEach(dueItems, id: \.objectID) { rowButton(for: $0) }
                }
            }

            Section("today.section.in_progress") {
                if inProgressItems.isEmpty {
                    emptyRow("today.empty.in_progress")
                } else {
                    ForEach(inProgressItems, id: \.objectID) { rowButton(for: $0) }
                }
            }

            Section("today.section.start") {
                if startItems.isEmpty {
                    emptyRow("today.empty.start")
                } else {
                    ForEach(startItems, id: \.objectID) { rowButton(for: $0) }
                }
            }

            Section("today.section.routine") {
                if routinesForDate.isEmpty {
                    emptyRow("today.empty.routine")
                } else {
                    ForEach(routinesForDate, id: \.objectID) { rowButton(for: $0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                referenceDate = Date()
            }
        }
    }

    private func rowButton(for item: Item) -> some View {
        Button {
            sheet = .edit(item)
        } label: {
            ItemRow(item: item, referenceDate: referenceDate)
        }
        .buttonStyle(.plain)
    }

    private func emptyRow(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .foregroundStyle(.secondary)
            .font(.subheadline)
    }
}

#Preview {
    NavigationStack { TodayView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
