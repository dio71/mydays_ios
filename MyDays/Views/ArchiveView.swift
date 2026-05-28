import CoreData
import SwiftUI

struct ArchiveView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: ItemSheetMode?
    @State private var entryText: String = ""
    @State private var showCompleted = false
    // ArchiveView는 isSomeday=true 항목만 보여주므로 사실상 referenceDate 영향 작지만,
    // 일관성을 위해 UTC anchor로 통일.
    @State private var referenceDate: Date = .todayCalendarAnchor
    /// 카테고리 필터 — nil = 전체.
    @State private var filterCategoryID: UUID?
    /// 카테고리 그룹핑 모드 — active section만. 완료는 그룹핑 무시.
    @State private var groupByCategory: Bool = false

    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Item.priority, order: .reverse), SortDescriptor(\Item.createdAt)],
        predicate: NSPredicate(format: "isSomeday == YES AND status == 0"),
        animation: .default
    )
    private var items: FetchedResults<Item>

    // 완료/취소 보관함 항목 — status 1(done) OR 3(failed).
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Item.completedAt, order: .reverse)],
        predicate: NSPredicate(format: "isSomeday == YES AND (status == 1 OR status == 3)"),
        animation: .default
    )
    private var completedItems: FetchedResults<Item>

    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Category.sortOrder), SortDescriptor(\Category.createdAt)],
        animation: .default
    )
    private var categories: FetchedResults<Category>

    private var filteredItems: [Item] {
        filterCategoryID.map { id in items.filter { $0.category?.id == id } }
            ?? Array(items)
    }

    private var filteredCompletedItems: [Item] {
        filterCategoryID.map { id in completedItems.filter { $0.category?.id == id } }
            ?? Array(completedItems)
    }

    /// 카테고리별 그룹 — 비어있는 카테고리 제외.
    private var groupedActiveItems: [(category: Category, items: [Item])] {
        var byID: [UUID: [Item]] = [:]
        for item in filteredItems {
            guard let cat = item.category, let id = cat.id else { continue }
            byID[id, default: []].append(item)
        }
        return categories.compactMap { cat in
            guard let id = cat.id, let items = byID[id], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }

    /// 카테고리 미설정 active 항목.
    private var uncategorizedActiveItems: [Item] {
        filteredItems.filter { $0.category == nil }
    }

    var body: some View {
        List {
            // 그룹 모드 / 평소 모드(필터 활성 시 header) 분기.
            if groupByCategory {
                let groups = groupedActiveItems
                let uncat = uncategorizedActiveItems
                if groups.isEmpty && uncat.isEmpty {
                    Section { emptyActiveRow }
                } else {
                    ForEach(groups, id: \.category.objectID) { group in
                        Section {
                            ForEach(group.items, id: \.objectID) { item in
                                archiveRow(for: item)
                            }
                        } header: {
                            categorySectionHeader(group.category)
                        }
                    }
                    if !uncat.isEmpty {
                        Section("list.group.uncategorized") {
                            ForEach(uncat, id: \.objectID) { item in
                                archiveRow(for: item)
                            }
                        }
                    }
                }
            } else if let id = filterCategoryID,
                      let cat = categories.first(where: { $0.id == id }) {
                Section {
                    activeContent
                } header: {
                    categorySectionHeader(cat)
                }
            } else {
                Section {
                    activeContent
                }
            }

            if showCompleted {
                Section("list.section.completed") {
                    let done = filteredCompletedItems
                    if done.isEmpty {
                        Text("list.empty.completed")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(done, id: \.objectID) { item in
                            Button {
                                sheet = .edit(item)
                            } label: {
                                ItemRow(item: item, referenceDate: referenceDate, mode: .list)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("archive.title")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !categories.isEmpty {
                    Button {
                        // 그룹 ON 전환 시 filter 초기화 (ListView와 동일).
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
        // 마지막 row가 입력 바에 가리지 않도록 스크롤 여백 확보 (입력 바 높이 + margin).
        .contentMargins(.bottom, 96, for: .scrollContent)
        // 하단 inline 입력 바 — overlay로 고정 위치 (탭 이동 시 위치 흔들림 방지).
        // safeAreaInset과 달리 overlay는 키보드 표시 시에도 자동으로 위로 올라옴 (iOS 기본 keyboard avoidance).
        .overlay(alignment: .bottom) {
            QuickEntryBar(
                text: $entryText,
                onSubmit: quickSave,
                // 필터 적용 중이면 그 카테고리를 신규 항목에도 preset.
                onEmptyTap: { sheet = .new(baseDate: nil, categoryID: filterCategoryID) }
            )
        }
        .sheet(item: $sheet) { mode in
            switch mode {
            case .new(let baseDate, let categoryID):
                AddItemView(baseDate: baseDate, categoryID: categoryID)
            case .edit(let item):
                AddItemView(editing: item)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                referenceDate = .todayCalendarAnchor
            }
        }
    }

    /// 평소(non-group) active 내용 — header 분기용.
    @ViewBuilder
    private var activeContent: some View {
        let active = filteredItems
        if active.isEmpty {
            emptyActiveRow
        } else {
            ForEach(active, id: \.objectID) { archiveRow(for: $0) }
        }
    }

    /// 보관함 row — group/flat 공용.
    private func archiveRow(for item: Item) -> some View {
        Button {
            sheet = .edit(item)
        } label: {
            ItemRow(item: item, referenceDate: referenceDate)
        }
        .buttonStyle(.plain)
    }

    /// 빈 상태 — "막연한 할일이 없습니다".
    private var emptyActiveRow: some View {
        Text("archive.empty")
            .foregroundStyle(.secondary)
            .font(.subheadline)
    }

    /// filter 활성 시 section header — ListView와 동일 패턴(filled circle icon + 이름).
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

    /// 카테고리 필터 Menu — ListView와 동일 패턴.
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
                    // 특정 카테고리 필터 선택 시 그룹 모드 해제 (ListView와 동일).
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

    /// 보관함 즉시 등록 — 제목만 받고 isSomeday=true로 저장. 나중에 탭해서 상세 편집.
    /// text reset은 QuickEntryBar가 책임짐.
    /// 카테고리 필터 적용 중이면 그 카테고리로 자동 분류.
    private func quickSave() {
        let title = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let item = Item.make(in: context, kind: .todo, title: title)
        item.isSomeday = true
        if let id = filterCategoryID,
           let cat = categories.first(where: { $0.id == id }) {
            item.category = cat
        }
        ItemEvent.log(.created, on: item, in: context)
        do {
            try context.save()
        } catch {
            assertionFailure("Quick save failed: \(error)")
        }
    }
}

#Preview {
    NavigationStack { ArchiveView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
