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
    /// 카테고리 필터 — nil = 전체, UUID = 그 카테고리만. 매 launch마다 초기화.
    @State private var filterCategoryID: UUID?
    /// 목표 유형 필터 — nil = 무관. categoryFilter와 상호 배타.
    @State private var filterGoalKind: ItemKind?
    /// 카테고리 그룹핑 모드 — true면 active section을 카테고리별 섹션으로 분리. 완료는 그룹핑 무시.
    /// 앱 재실행 시 마지막 상태 복원.
    @AppStorage(UIStateKey.listGroupByCategory) private var groupByCategory: Bool = false
    /// 검색 모드 — 돋보기 toolbar 버튼으로 진입. true면 상단에 검색 입력 banner + 본문 검색 결과로 전환,
    /// 다른 toolbar 버튼/(+) FAB 숨김. 사용자가 banner의 cancel 버튼 누르면 false 복귀.
    /// (TodayView의 cancelMode/pickerMode banner 패턴과 통일 — `.searchable` 대신 자체 banner.)
    @State private var searchPresented: Bool = false
    @State private var searchText: String = ""
    @FocusState private var searchFieldFocused: Bool

    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Category.sortOrder), SortDescriptor(\Category.createdAt)],
        animation: .default
    )
    private var categories: FetchedResults<Category>

    // 태그 추출용 fetch — 목록탭 범위의 notes가 '#' 포함된 항목만.
    // SearchResultsList의 매 searchText 변경마다 inner struct가 재초기화되므로 outer에 둠.
    @FetchRequest(
        sortDescriptors: [],
        predicate: NSPredicate(format: "isSomeday == NO AND status != 2 AND notes CONTAINS '#'"),
        animation: .default
    )
    private var taggedItems: FetchedResults<Item>

    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Item.createdAt)],
        predicate: NSPredicate(format: "status == 0 AND isSomeday == NO"),
        animation: .default
    )
    private var activeItems: FetchedResults<Item>

    /// 단일 필터 정책: 카테고리 또는 목표 유형 중 하나만 활성.
    /// - 카테고리: Todo + category 매칭 (목표 hide)
    /// - 목표 유형: 그 type만 (Todo + 다른 목표 hide)
    private func matchesFilter(_ item: Item) -> Bool {
        if let id = filterCategoryID {
            return item.itemKind == .todo && item.category?.id == id
        }
        if let kind = filterGoalKind {
            return item.itemKind == kind
        }
        return true
    }

    /// d-day 빠른 순(가까운 마감 먼저). 동률이면 NTD 우선.
    private var sortedActiveItems: [Item] {
        let filtered = activeItems.filter { matchesFilter($0) }
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

    /// 완료 섹션 — 동일 필터 적용.
    private var filteredCompletedItems: [Item] {
        completedItems.filter { matchesFilter($0) }
    }

    /// 그룹핑 모드 — 카테고리별 (Category, [Item]). 비어있는 카테고리는 제외. 미분류는 별도로 표시.
    /// 각 그룹 안 정렬은 sortedActiveItems 순서 유지 (d-day 빠른 순).
    /// **목표는 별도 그룹** — `goalItemsForGroup`에서 처리, 여기는 Todo 카테고리만.
    private var groupedActiveItems: [(category: Category, items: [Item])] {
        var byID: [UUID: [Item]] = [:]
        for item in sortedActiveItems where !item.itemKind.isGoal {
            guard let cat = item.category, let id = cat.id else { continue }
            byID[id, default: []].append(item)
        }
        return categories.compactMap { cat in
            guard let id = cat.id, let items = byID[id], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }

    /// 그룹 모드 최상단 "목표" 그룹 — 절제/활동/집중/습관 모두 포함.
    private var goalItemsForGroup: [Item] {
        sortedActiveItems.filter { $0.itemKind.isGoal }
    }

    /// 카테고리 미설정 active 항목 — "미분류" 섹션용. 목표는 제외 (별도 그룹).
    private var uncategorizedActiveItems: [Item] {
        sortedActiveItems.filter { $0.category == nil && !$0.itemKind.isGoal }
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
        let hasFilter = filterCategoryID != nil || filterGoalKind != nil
        Group {
            if searchPresented {
                searchResultsList
            } else {
                normalList(hasFilter: hasFilter)
            }
        }
        // listStyle은 inner의 각 List에 직접 부착 (normalList=insetGrouped, search=plain).
        // outer Group에 부착하면 inner의 plain override가 일부 환경에서 풀림.
        // iPad/regular size class에서 content 폭 cap — 가독성.
        .iPadContentWidth()
        // 하단 (+) FAB(56pt + padding 20pt)에 마지막 row가 가리지 않도록 스크롤 여백 확보.
        // 검색 모드는 FAB 숨김이라 여백 불필요.
        .contentMargins(.bottom, searchPresented ? 0 : 96, for: .scrollContent)
        .navigationTitle(searchPresented ? "list.search.title" : "list.title")
        .navigationBarTitleDisplayMode(searchPresented ? .inline : .large)
        // 검색 모드 banner — TodayView의 cancelModeBanner/pickerModeBanner와 동일 스타일.
        // 검색 모드 진입 시에만 노출되어 영구 검색바 영역이 자리 차지하지 않음.
        .safeAreaInset(edge: .top, spacing: 0) {
            if searchPresented {
                searchBanner
            }
        }
        .toolbar {
            if searchPresented {
                // 검색 모드 — TodayView cancel/picker 모드와 동일 패턴 (우상단 prominent checkmark).
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        searchPresented = false
                    } label: {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .accessibilityLabel("common.done")
                }
            } else {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        searchPresented = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    if !categories.isEmpty {
                        Button {
                            if !groupByCategory {
                                filterCategoryID = nil
                                filterGoalKind = nil
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
        }
        .overlay(alignment: .bottomTrailing) {
            if !searchPresented {
                Button {
                    sheet = .new(baseDate: .todayCalendarAnchor, categoryID: filterCategoryID, goalKind: filterGoalKind)
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
        }
        .sheet(item: $sheet) { mode in
            switch mode {
            case .new(let baseDate, let categoryID, let goalKind):
                AddItemView(baseDate: baseDate, categoryID: categoryID, goalKind: goalKind)
            case .edit(let item):
                AddItemView(editing: item)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openNewItemForCurrentTab)) { note in
            guard (note.object as? SidebarItem) == .list else { return }
            sheet = .new(baseDate: .todayCalendarAnchor, categoryID: filterCategoryID, goalKind: filterGoalKind)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                referenceDate = .todayCalendarAnchor
            }
        }
        // 검색 종료 시 searchText 정리. 진입 시 자동 focus.
        .onChange(of: searchPresented) { _, newValue in
            if newValue {
                // banner appearance 직후 focus — 약간 delay로 키보드 자연스럽게 올라옴.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    searchFieldFocused = true
                }
            } else {
                searchText = ""
                searchFieldFocused = false
            }
        }
        .task {
            Item.completeExpiredRoutines(in: context)
            Item.completeFinishedNTDs(in: context)
        }
    }

    // MARK: - Normal list (검색 모드 아님)

    @ViewBuilder
    private func normalList(hasFilter: Bool) -> some View {
        // 진짜 empty (Case A) — 필터 없음 + 활성 0개 + 완료 섹션 0개(또는 토글 OFF).
        // first-launch 또는 완전 비어있는 상태. 필터/토글 적용 empty는 기존 emptyRow 유지.
        if !hasFilter && sortedActiveItems.isEmpty && (!showCompleted || filteredCompletedItems.isEmpty) {
            EmptyStateView(iconName: "note.text", message: "list.empty.first")
        } else {
        List {
            if hasFilter {
                // 필터 활성 — 단일 섹션 (카테고리 필터=그 카테고리 Todo만, 목표 유형=그 type만).
                let items = sortedActiveItems
                Section {
                    if items.isEmpty {
                        emptyRow("list.empty.active")
                    } else {
                        ForEach(items, id: \.objectID) { rowButton(for: $0) }
                    }
                } header: {
                    filterSectionHeader
                }
            } else if groupByCategory {
                // 그룹 모드 — 목표 그룹 최상단 + 카테고리별 + 미분류.
                let goals = goalItemsForGroup
                let groups = groupedActiveItems
                let uncat = uncategorizedActiveItems
                if goals.isEmpty && groups.isEmpty && uncat.isEmpty {
                    Section { emptyRow("list.empty.active") }
                } else {
                    if !goals.isEmpty {
                        Section("list.group.goals") {
                            ForEach(goals, id: \.objectID) { rowButton(for: $0) }
                        }
                    }
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
                // 필터 없음 + 평소 모드 — 단일 섹션.
                Section {
                    flatActiveContent
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
        }
    }

    // MARK: - Search banner
    //
    // TodayView의 cancelModeBanner/pickerModeBanner와 동일 시각(옅은 accent 배경).
    // 검색 입력 capsule만 차지 — 종료는 toolbar의 우상단 (v) prominent 버튼으로 (TodayView 패턴 통일).
    @ViewBuilder
    private var searchBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(text: $searchText, prompt: Text("list.search.prompt")) {
                EmptyView()
            }
            .focused($searchFieldFocused)
            .submitLabel(.search)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // banner 배경(accent.opacity 0.12) 위에 capsule은 systemBackground로 — 흰/검 자동 적응.
        .background(Capsule().fill(Color(.systemBackground)))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.12))
    }

    // MARK: - Search results
    //
    // 검색 모드 본문 — title 또는 notes에 검색어가 포함된 모든 목록탭 항목(isSomeday=NO).
    // 완료(status 1) + 포기(status 3) + 진행 중(status 0) 모두 포함. deleted(2)만 제외.
    // 빈 검색어 → 빈 화면 (placeholder).
    @ViewBuilder
    private var searchResultsList: some View {
        // searchText를 init에 넘겨 predicate 동적 갱신. 검색어 변경 시 inner struct가 새로 초기화되며 fetch 재실행.
        // tags는 빈 검색어 상태에서 chip section으로 노출 — chip 탭 시 searchText에 replace.
        SearchResultsList(
            searchText: searchText,
            tags: allTags,
            referenceDate: referenceDate,
            onTagTap: { tag in
                searchText = tag
            },
            onTap: { item in
                sheet = .edit(item)
            }
        )
    }

    /// notes에 포함된 모든 `#xxxx` 태그 unique set (정렬). 한국어·영문·숫자·언더스코어 지원 (Unicode-aware).
    private var allTags: [String] {
        var set = Set<String>()
        for item in taggedItems {
            guard let notes = item.notes else { continue }
            set.formUnion(Self.extractTags(from: notes))
        }
        return set.sorted()
    }

    private static let tagPattern: NSRegularExpression? = try? NSRegularExpression(pattern: "#[\\p{L}\\p{N}_]+")

    private static func extractTags(from notes: String) -> Set<String> {
        guard let regex = tagPattern else { return [] }
        let range = NSRange(notes.startIndex..., in: notes)
        let matches = regex.matches(in: notes, range: range)
        return Set(matches.compactMap { match in
            Range(match.range, in: notes).map { String(notes[$0]) }
        })
    }

    /// 검색 결과 inner view — `@FetchRequest`의 predicate를 init에서 동적 설정하는 패턴.
    /// tags chip section은 빈 검색어 시 상단에 노출 — chip 탭 시 onTagTap 호출.
    private struct SearchResultsList: View {
        @FetchRequest var items: FetchedResults<Item>
        let tags: [String]
        let onTagTap: (String) -> Void
        let onTap: (Item) -> Void
        let trimmed: String
        let referenceDate: Date

        init(
            searchText: String,
            tags: [String],
            referenceDate: Date,
            onTagTap: @escaping (String) -> Void,
            onTap: @escaping (Item) -> Void
        ) {
            self.tags = tags
            self.onTagTap = onTagTap
            self.onTap = onTap
            self.referenceDate = referenceDate
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.trimmed = trimmed
            let predicate: NSPredicate
            if trimmed.isEmpty {
                // 빈 검색어 — 매칭 0건 강제 (빈 결과 → empty placeholder).
                predicate = NSPredicate(value: false)
            } else {
                // isSomeday=NO + deleted 제외 + (title OR notes) CONTAINS[c] 검색어.
                predicate = NSPredicate(
                    format: "isSomeday == NO AND status != %d AND (title CONTAINS[c] %@ OR notes CONTAINS[c] %@)",
                    Status.deleted.rawValue, trimmed, trimmed
                )
            }
            _items = FetchRequest(
                sortDescriptors: [
                    SortDescriptor(\Item.completedAt, order: .reverse),
                    SortDescriptor(\Item.updatedAt, order: .reverse)
                ],
                predicate: predicate,
                animation: .default
            )
        }

        var body: some View {
            // List 컨테이너를 항상 유지 — empty → results 전환 시 view tree 재구성 방지.
            // 그렇지 않으면 첫 char 입력 시 컨테이너 변화로 TextField focus 잃음 → 키보드 dismiss.
            List {
                // 태그 chip — 검색어 유무 무관 항상 노출 (태그 1개 이상이면).
                // 단일 row 그대로 — 결과는 별도 Section으로 묶어 시각 분리.
                if !tags.isEmpty {
                    tagChipRow
                }
                Section {
                    if trimmed.isEmpty {
                        emptyRow("list.search.prompt_input")
                    } else if items.isEmpty {
                        emptyRow("list.search.no_results")
                    } else {
                        ForEach(items, id: \.objectID) { item in
                            Button { onTap(item) } label: {
                                ItemRow(
                                    item: item,
                                    referenceDate: referenceDate,
                                    mode: .list
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            // 결과 스크롤 시 키보드 자동 dismiss — 좁은 화면에서 답답함 해소.
            .scrollDismissesKeyboard(.immediately)
            // normalList와 통일 — 태그 chip 위 작은 여백은 insetGrouped 자체 동작이라 수용.
            .listStyle(.insetGrouped)
        }

        /// 태그 chip 가로 스크롤 행. List row 1개 안에 ScrollView로 배치 — wrap 보다 단순.
        @ViewBuilder
        private var tagChipRow: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            onTagTap(tag)
                        } label: {
                            Text(verbatim: tag)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }

        @ViewBuilder
        private func emptyRow(_ key: LocalizedStringKey) -> some View {
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(key)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 40)
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
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

    /// 필터 활성 시 섹션 헤더 — 카테고리 또는 목표 유형 표시.
    @ViewBuilder
    private var filterSectionHeader: some View {
        if let id = filterCategoryID,
           let cat = categories.first(where: { $0.id == id }) {
            categorySectionHeader(cat)
        } else if let kind = filterGoalKind {
            HStack(spacing: 8) {
                Image(systemName: kind.goalTypeSymbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.accentColor))
                Text(verbatim: kind.displayName)
            }
        }
    }

    /// 필터 옵션 순서.
    private static let goalKindFilterOrder: [ItemKind] = [.notTodo, .activity, .focus, .habit]

    /// 통합 필터 Menu — "모두" + 카테고리 section + 목표 유형 section. 단일 필터 정책 (상호 배타).
    @ViewBuilder
    private var categoryFilterMenu: some View {
        Menu {
            Button {
                filterCategoryID = nil
                filterGoalKind = nil
            } label: {
                if filterCategoryID == nil && filterGoalKind == nil {
                    Label("list.filter.all", systemImage: "checkmark")
                } else {
                    Text("list.filter.all")
                }
            }
            // 카테고리 section — divider만, title 없음.
            if !categories.isEmpty {
                Section {
                    ForEach(categories, id: \.id) { cat in
                        Button {
                            filterCategoryID = cat.id
                            filterGoalKind = nil
                            groupByCategory = false  // 필터 활성 시 그룹 모드 해제.
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
                }
            }
            // 목표 유형 section — divider만.
            Section {
                ForEach(Self.goalKindFilterOrder, id: \.self) { kind in
                    Button {
                        filterGoalKind = kind
                        filterCategoryID = nil
                        groupByCategory = false
                    } label: {
                        if filterGoalKind == kind {
                            Label(kind.displayName, systemImage: "checkmark")
                        } else {
                            Label {
                                Text(verbatim: kind.displayName)
                            } icon: {
                                Image(systemName: kind.goalTypeSymbolName)
                            }
                        }
                    }
                }
            }
        } label: {
            let active = filterCategoryID != nil || filterGoalKind != nil
            Image(systemName: active
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
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
