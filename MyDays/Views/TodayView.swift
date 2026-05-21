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
                    }
                }
                if isFarFuture {
                    if #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .topBarLeading)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: jumpToToday) {
                            Text(jumpHomeLabel)
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(navigationTitle)
                        .font(.headline)
                }
                if isFarPast {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: jumpToToday) {
                            Text(jumpHomeLabel)
                        }
                    }
                    if #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { shiftDay(1) } label: {
                        Image(systemName: "chevron.right")
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

    private var jumpHomeLabel: String {
        let preferred = Locale.preferredLanguages.first ?? ""
        return preferred.hasPrefix("ko") ? "오늘" : "Today"
    }

    private var navigationTitle: String {
        switch daysFromToday {
        case 0:  return "오늘"
        case 1:  return "내일"
        case -1: return "어제"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "M월 d일 (E)"
            return formatter.string(from: displayedDate)
        }
    }
}

struct TodayList: View {

    @Binding var sheet: ItemSheetMode?

    @FetchRequest var dueItems: FetchedResults<Item>
    @FetchRequest var inProgressItems: FetchedResults<Item>
    @FetchRequest var startItems: FetchedResults<Item>

    init(date: Date, sheet: Binding<ItemSheetMode?>) {
        self._sheet = sheet
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let sort = [SortDescriptor(\Item.priority, order: .reverse), SortDescriptor(\Item.createdAt)]

        _dueItems = FetchRequest(
            sortDescriptors: sort,
            predicate: NSPredicate(
                format: "dueDate >= %@ AND dueDate < %@ AND status == 0",
                start as NSDate, end as NSDate
            ),
            animation: .default
        )
        _inProgressItems = FetchRequest(
            sortDescriptors: sort,
            predicate: NSPredicate(
                format: "startDate < %@ AND dueDate >= %@ AND status == 0",
                start as NSDate, end as NSDate
            ),
            animation: .default
        )
        _startItems = FetchRequest(
            sortDescriptors: sort,
            predicate: NSPredicate(
                format: "startDate >= %@ AND startDate < %@ AND status == 0 AND (dueDate == nil OR dueDate >= %@)",
                start as NSDate, end as NSDate, end as NSDate
            ),
            animation: .default
        )
    }

    var body: some View {
        List {
            Section("진행 중 Not Todo") {
                emptyRow("진행 중인 Not Todo가 없습니다")
            }

            Section("마감") {
                if dueItems.isEmpty {
                    emptyRow("마감인 할일이 없습니다")
                } else {
                    ForEach(dueItems, id: \.objectID) { rowButton(for: $0) }
                }
            }

            Section("진행 중") {
                if inProgressItems.isEmpty {
                    emptyRow("진행 중인 할일이 없습니다")
                } else {
                    ForEach(inProgressItems, id: \.objectID) { rowButton(for: $0) }
                }
            }

            Section("시작") {
                if startItems.isEmpty {
                    emptyRow("시작하는 할일이 없습니다")
                } else {
                    ForEach(startItems, id: \.objectID) { rowButton(for: $0) }
                }
            }

            Section("루틴") {
                emptyRow("루틴이 없습니다")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func rowButton(for item: Item) -> some View {
        Button {
            sheet = .edit(item)
        } label: {
            ItemRow(item: item)
        }
        .buttonStyle(.plain)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(.subheadline)
    }
}

#Preview {
    NavigationStack { TodayView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
