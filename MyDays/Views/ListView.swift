import CoreData
import SwiftUI

struct ListView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: ItemSheetMode?
    // 완료 섹션 표시 — 앱 재실행 시 마지막 토글 상태 복원 (@AppStorage).
    @AppStorage(UIStateKey.listShowCompleted) private var showCompleted: Bool = false
    // referenceDate는 daysUntilDue 등 calendar date 비교 기준 → UTC anchor.
    // 자정 넘어가면 onChange/.task에서 다시 .todayCalendarAnchor로 갱신.
    @State private var referenceDate: Date = .todayCalendarAnchor
    /// 카테고리 필터 — nil = 전체, UUID = 그 카테고리만. 매 launch마다 초기화 (저장 X — 사용자 결정).
    @State private var filterCategoryID: UUID?
    /// 카테고리 그룹핑 모드 — true면 active section을 카테고리별 섹션으로 분리. 완료는 그룹핑 무시.
    /// 앱 재실행 시 마지막 상태 복원.
    @AppStorage(UIStateKey.listGroupByCategory) private var groupByCategory: Bool = false

    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Category.sortOrder), SortDescriptor(\Category.createdAt)],
        animation: .default
    )
    private var categories: FetchedResults<Category>

    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Item.createdAt)],
        predicate: NSPredicate(format: "status == 0 AND isSomeday == NO"),
        animation: .default
    )
    private var activeItems: FetchedResults<Item>

    /// d-day 빠른 순(가까운 마감 먼저). 동률이면 NTD 우선.
    /// d-day는 1회성=daysUntilDue, 반복=daysUntilNextOccurrence.
    /// `filterCategoryID` 적용 — nil 또는 매칭 항목만.
    private var sortedActiveItems: [Item] {
        let filtered = filterCategoryID.map { id in
            activeItems.filter { $0.category?.id == id }
        } ?? Array(activeItems)
        return filtered.sorted { a, b in
            let dA = Self.dDayValue(a, referenceDate: referenceDate)
            let dB = Self.dDayValue(b, referenceDate: referenceDate)
            if dA != dB { return dA < dB }
            if a.itemKind != b.itemKind {
                return a.itemKind == .notTodo
            }
            return (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast)
        }
    }

    /// 완료 섹션 — 카테고리 필터 동일 적용.
    private var filteredCompletedItems: [Item] {
        filterCategoryID.map { id in
            completedItems.filter { $0.category?.id == id }
        } ?? Array(completedItems)
    }

    /// 그룹핑 모드 — 카테고리별 (Category, [Item]). 비어있는 카테고리는 제외. 미분류는 별도로 표시.
    /// 각 그룹 안 정렬은 sortedActiveItems 순서 유지 (d-day 빠른 순).
    private var groupedActiveItems: [(category: Category, items: [Item])] {
        var byID: [UUID: [Item]] = [:]
        for item in sortedActiveItems {
            guard let cat = item.category, let id = cat.id else { continue }
            byID[id, default: []].append(item)
        }
        return categories.compactMap { cat in
            guard let id = cat.id, let items = byID[id], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }

    /// 카테고리 미설정 active 항목 — "미분류" 섹션용.
    private var uncategorizedActiveItems: [Item] {
        sortedActiveItems.filter { $0.category == nil }
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
            // 진행 중 — 그룹핑 모드 분기. 평소 모드는 단일 섹션, 그룹 모드는 카테고리별 분리.
            if groupByCategory {
                let groups = groupedActiveItems
                let uncat = uncategorizedActiveItems
                if groups.isEmpty && uncat.isEmpty {
                    Section { emptyRow("list.empty.active") }
                } else {
                    ForEach(groups, id: \.category.objectID) { group in
                        Section {
                            ForEach(group.items, id: \.objectID) { rowButton(for: $0) }
                        } header: {
                            categorySectionHeader(group.category)
                        }
                    }
                    if !uncat.isEmpty {
                        Section("list.group.uncategorized") {
                            ForEach(uncat, id: \.objectID) { rowButton(for: $0) }
                        }
                    }
                }
            } else {
                // 평소 모드 — filter 활성 시 해당 카테고리를 섹션 헤더로 표시.
                if let id = filterCategoryID,
                   let cat = categories.first(where: { $0.id == id }) {
                    Section {
                        flatActiveContent
                    } header: {
                        categorySectionHeader(cat)
                    }
                } else {
                    Section {
                        flatActiveContent
                    }
                }
            }

            if showCompleted {
                Section("list.section.completed") {
                    let items = filteredCompletedItems
                    if items.isEmpty {
                        emptyRow("list.empty.completed")
                    } else {
                        ForEach(items, id: \.objectID) { rowButton(for: $0) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // iPad/regular size class에서 content 폭 cap — 가독성.
        .iPadContentWidth()
        // 하단 (+) FAB(56pt + padding 20pt)에 마지막 row가 가리지 않도록 스크롤 여백 확보.
        .contentMargins(.bottom, 96, for: .scrollContent)
        .navigationTitle("list.title")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !categories.isEmpty {
                    Button {
                        // 그룹핑 ON 시 필터를 자동으로 "모두"로 초기화 — 필터+그룹 동시면 단일 그룹만 보여 의미 X.
                        if !groupByCategory {
                            filterCategoryID = nil
                        }
                        groupByCategory.toggle()
                    } label: {
                        Image(systemName: groupByCategory ? "square.stack.fill" : "square.stack")
                    }
                    categoryFilterMenu
                }
                Button {
                    showCompleted.toggle()
                } label: {
                    Image(systemName: showCompleted ? "checklist" : "checklist.unchecked")
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                // 신규 항목 default: 오늘 일정으로 preset (TodayView와 동일).
                // 카테고리 필터 적용 중이면 그 카테고리를 신규 항목에도 preset.
                sheet = .new(baseDate: .todayCalendarAnchor, categoryID: filterCategoryID)
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
            case .new(let baseDate, let categoryID):
                AddItemView(baseDate: baseDate, categoryID: categoryID)
            case .edit(let item):
                AddItemView(editing: item)
            }
        }
        // ⌘N — RootView가 currentTab과 함께 broadcast. .list일 때만 새 항목 열기.
        .onReceive(NotificationCenter.default.publisher(for: .openNewItemForCurrentTab)) { note in
            guard (note.object as? SidebarItem) == .list else { return }
            sheet = .new(baseDate: .todayCalendarAnchor, categoryID: filterCategoryID)
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

    /// 평소(non-group) 모드 active section 내용 — section header 분기 위한 추출.
    @ViewBuilder
    private var flatActiveContent: some View {
        if sortedActiveItems.isEmpty {
            emptyRow("list.empty.active")
        } else {
            ForEach(sortedActiveItems, id: \.objectID) { rowButton(for: $0) }
        }
    }

    /// 그룹 모드 section header — filled circle icon + 카테고리 이름.
    @ViewBuilder
    private func categorySectionHeader(_ cat: Category) -> some View {
        HStack(spacing: 8) {
            Image(systemName: cat.iconName ?? CategoryIcon.defaultIcon.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(CategoryRowView.categoryColor(for: cat)))
            Text(verbatim: cat.name ?? "")
        }
    }

    /// 카테고리 필터 Menu — "모두" + 각 카테고리. 활성 시 아이콘 filled로 표시.
    @ViewBuilder
    private var categoryFilterMenu: some View {
        Menu {
            Button {
                filterCategoryID = nil
            } label: {
                if filterCategoryID == nil {
                    Label("list.filter.all", systemImage: "checkmark")
                } else {
                    Text("list.filter.all")
                }
            }
            ForEach(categories, id: \.id) { cat in
                Button {
                    filterCategoryID = cat.id
                    // 특정 카테고리 필터 선택 시 그룹 모드 해제 — 필터+그룹 동시면 단일 그룹만 보여 의미 X.
                    // "모두" 선택은 그룹 모드 유지 (모든 카테고리 그룹 보기 유효).
                    groupByCategory = false
                } label: {
                    if filterCategoryID == cat.id {
                        Label(cat.name ?? "", systemImage: "checkmark")
                    } else {
                        Label {
                            Text(verbatim: cat.name ?? "")
                        } icon: {
                            Image(systemName: cat.iconName ?? CategoryIcon.defaultIcon.symbolName)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: filterCategoryID == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
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
