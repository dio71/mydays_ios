import CoreData
import SwiftUI

struct ListView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: ItemSheetMode?
    @State private var showCompleted = false
    // referenceDate는 daysUntilDue 등 calendar date 비교 기준 → UTC anchor.
    // 자정 넘어가면 onChange/.task에서 다시 .todayCalendarAnchor로 갱신.
    @State private var referenceDate: Date = .todayCalendarAnchor

    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Item.createdAt)],
        predicate: NSPredicate(format: "status == 0 AND isSomeday == NO"),
        animation: .default
    )
    private var activeItems: FetchedResults<Item>

    /// d-day 빠른 순(가까운 마감 먼저). 동률이면 NTD 우선.
    /// d-day는 1회성=daysUntilDue, 반복=daysUntilNextOccurrence.
    private var sortedActiveItems: [Item] {
        activeItems.sorted { a, b in
            let dA = Self.dDayValue(a, referenceDate: referenceDate)
            let dB = Self.dDayValue(b, referenceDate: referenceDate)
            if dA != dB { return dA < dB }
            // 동률 — NTD가 먼저
            if a.itemKind != b.itemKind {
                return a.itemKind == .notTodo
            }
            return (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast)
        }
    }

    private static func dDayValue(_ item: Item, referenceDate: Date) -> Int {
        if item.recurrenceRule != nil {
            return item.daysUntilNextOccurrence(referenceDate: referenceDate) ?? Int.max
        }
        return item.daysUntilDue(referenceDate: referenceDate) ?? Int.max
    }

    // 완료 섹션은 done(1) + failed(3, NTD 포기) 모두 포함.
    // status: 0=pending, 1=done, 2=deleted, 3=failed.
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Item.completedAt, order: .reverse)],
        predicate: NSPredicate(format: "(status == 1 OR status == 3) AND isSomeday == NO"),
        animation: .default
    )
    private var completedItems: FetchedResults<Item>

    var body: some View {
        // ItemRow가 자체 TimelineView로 실시간 갱신하므로 ListView 레벨 refresh 불필요.
        List {
            // 진행 중 섹션 — 헤더 없이 (페이지 타이틀이 "전체 활동"으로 정체성 제공).
            Section {
                if sortedActiveItems.isEmpty {
                    emptyRow("list.empty.active")
                } else {
                    ForEach(sortedActiveItems, id: \.objectID) { rowButton(for: $0) }
                }
            }

            if showCompleted {
                Section("list.section.completed") {
                    if completedItems.isEmpty {
                        emptyRow("list.empty.completed")
                    } else {
                        ForEach(completedItems, id: \.objectID) { rowButton(for: $0) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // 하단 (+) FAB(56pt + padding 20pt)에 마지막 row가 가리지 않도록 스크롤 여백 확보.
        .contentMargins(.bottom, 96, for: .scrollContent)
        .navigationTitle("list.title")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCompleted.toggle()
                } label: {
                    Image(systemName: showCompleted ? "eye" : "eye.slash")
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                // 신규 항목 default: 오늘 일정으로 preset (TodayView와 동일).
                sheet = .new(baseDate: .todayCalendarAnchor)
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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                referenceDate = .todayCalendarAnchor
            }
        }
        .task {
            Item.completeExpiredRoutines(in: context)
            Item.completeFinishedNTDs(in: context)
        }
    }

    private func rowButton(for item: Item) -> some View {
        Button {
            sheet = .edit(item)
        } label: {
            ItemRow(
                item: item,
                referenceDate: referenceDate,
                mode: .list
            )
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
    NavigationStack { ListView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
