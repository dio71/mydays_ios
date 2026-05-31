import CoreData
import SwiftUI

// MARK: - ActivityHistoryView
//
// RoutineCompletion 기반 활동 기록 화면.
// - 진입 모드:
//   · per-item (`item != nil`): 그 item의 RC만. AddItemView "전체 보기 →"에서 진입.
//   · all-item + scope `.todo` (`item == nil, scope = .todo`): 할일 기록만. Settings 메뉴.
//   · all-item + scope `.goal` (`item == nil, scope = .goal`): 목표 기록만. Settings 메뉴.
// - 정렬: completedAt desc (없으면 date desc fallback). view-side 재정렬로 legacy progress record 처리.
// - Section: 월 단위 ("2026년 5월" 같은 형식).
// - 상태 필터: 전체 / 완료만 / 포기만.
// - 카테고리/목표 유형 필터 — scope별로 다름:
//   · .todo: 카테고리 필터
//   · .goal: 목표 유형 필터 (절제/활동/집중/습관)
// - All-item 검색: title + notes substring match.

struct ActivityHistoryView: View {

    let item: Item?
    /// all-item 모드의 분리 axis. per-item에선 무시.
    let scope: HistoryScope

    @Environment(\.managedObjectContext) private var context
    @State private var filter: HistoryFilter = .all
    @State private var filterCategoryID: UUID?
    /// 목표 유형 필터 — scope=.goal일 때만 사용. nil=모든 목표 type.
    @State private var filterGoalKind: ItemKind?
    @State private var searchText: String = ""

    // FetchRequest로 RC 직접 fetch. predicate는 item != nil이면 item만, nil이면 전체.
    @FetchRequest private var records: FetchedResults<RoutineCompletion>

    /// all-item scope=.todo 모드 카테고리 필터용.
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Category.sortOrder), SortDescriptor(\Category.name)],
        animation: .default
    )
    private var categories: FetchedResults<Category>

    enum HistoryScope {
        case todo, goal
    }

    enum HistoryFilter: String, CaseIterable, Identifiable {
        case all, done, failed
        var id: String { rawValue }
        var labelKey: LocalizedStringKey {
            switch self {
            case .all:    return "activity_history.filter.all"
            case .done:   return "activity_history.filter.done"
            case .failed: return "activity_history.filter.failed"
            }
        }
    }

    /// 목표 유형 필터 메뉴 — scope=.goal일 때 노출.
    /// nil=전체, 절제/활동/집중/습관 중 하나 선택.
    private static let goalKindOptions: [ItemKind] = [.notTodo, .activity, .focus, .habit]

    init(item: Item?, scope: HistoryScope = .todo) {
        self.item = item
        self.scope = scope
        // 단순화: item 매칭만 predicate로. done/failed/valueRecorded·kind 필터는 view-side(filteredRecords)에서 처리.
        // Core Data NSPredicate의 Optional NSNumber 비교(`valueRecorded > 0`)가 일부 경우 nil 매칭 이슈가 있어 회피.
        let predicate: NSPredicate
        if let item {
            predicate = NSPredicate(format: "item == %@", item)
        } else {
            predicate = NSPredicate(format: "item != nil")
        }
        _records = FetchRequest(
            sortDescriptors: [
                SortDescriptor(\RoutineCompletion.completedAt, order: .reverse),
                SortDescriptor(\RoutineCompletion.date, order: .reverse)
            ],
            predicate: predicate,
            animation: .default
        )
    }

    // MARK: - Filtering

    /// 사용자 입력 검색·필터 적용 결과 — 항상 view-side filter (단순, 수천 건도 무리 X).
    private var filteredRecords: [RoutineCompletion] {
        let filtered = records.filter { rc in
            // 표시 대상: done OR failed OR (활동 progress: valueRecorded > 0)
            let value = rc.valueRecorded?.doubleValue ?? 0
            let isDisplayable = rc.done || rc.failed || value > 0
            if !isDisplayable { return false }
            // 상태 필터 (사용자 선택)
            switch filter {
            case .all: break
            case .done: if !rc.done { return false }
            case .failed: if !rc.failed { return false }
            }
            // all-item 모드: scope별 kind 분리 + 추가 필터.
            if item == nil {
                guard let kind = rc.item?.itemKind else { return false }
                switch scope {
                case .todo:
                    // 할일 기록 — kind == .todo만.
                    if kind != .todo { return false }
                    // 카테고리 필터.
                    if let catID = filterCategoryID, rc.item?.category?.id != catID {
                        return false
                    }
                case .goal:
                    // 목표 기록 — isGoal만.
                    if !kind.isGoal { return false }
                    // 목표 유형 필터.
                    if let goalKind = filterGoalKind, kind != goalKind {
                        return false
                    }
                }
                // 검색 (scope 무관).
                let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let title = rc.item?.title ?? ""
                    let notes = rc.item?.notes ?? ""
                    if !title.localizedCaseInsensitiveContains(trimmed),
                       !notes.localizedCaseInsensitiveContains(trimmed) {
                        return false
                    }
                }
            }
            return true
        }
        // view-side 재정렬 — completedAt nil인 legacy progress record가 맨 아래로 가지 않게.
        // 정렬 키: completedAt ?? date ?? .distantPast (최신순).
        return filtered.sorted {
            let l = $0.completedAt ?? $0.date ?? .distantPast
            let r = $1.completedAt ?? $1.date ?? .distantPast
            return l > r
        }
    }

    // MARK: - Grouping

    /// 월 단위 section grouping. key = "yyyy-MM" 정렬 + display label "yyyy년 M월".
    private var groupedByMonth: [(monthKey: String, label: String, rows: [RoutineCompletion])] {
        let cal = Calendar.current
        var buckets: [String: [RoutineCompletion]] = [:]
        for rc in filteredRecords {
            // 정렬·표시는 completedAt 기준 (local). 없으면 date(UTC anchor) fallback.
            let dateForGroup = rc.completedAt ?? rc.date ?? .distantPast
            let comps = cal.dateComponents([.year, .month], from: dateForGroup)
            let key = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            buckets[key, default: []].append(rc)
        }
        let sortedKeys = buckets.keys.sorted(by: >)
        return sortedKeys.map { key in
            let rows = buckets[key] ?? []
            // 표시 label — "yyyy년 M월" 로컬라이즈.
            let label: String = {
                if let first = rows.first,
                   let inst = first.completedAt ?? first.date {
                    let f = DateFormatter()
                    f.locale = Locale.current
                    f.setLocalizedDateFormatFromTemplate("yMMMM")
                    return f.string(from: inst)
                }
                return key
            }()
            return (key, label, rows)
        }
    }

    // MARK: - body

    var body: some View {
        Group {
            if filteredRecords.isEmpty {
                emptyState
            } else {
                listContent
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 필터 활성 시 — title에 활성 필터 명칭 prefix. ToolbarItem(.principal)로 기본 title 대체.
            //   .todo + 카테고리 선택: "<카테고리명> 기록"
            //   .goal + 목표 유형 선택: "<유형> 목표 기록"
            if let filteredTitle = filteredNavigationTitle {
                ToolbarItem(placement: .principal) {
                    Text(verbatim: filteredTitle)
                        .font(.headline)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
            if item == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    // scope별 필터 메뉴 — todo는 카테고리, goal은 목표 유형.
                    switch scope {
                    case .todo: categoryFilterMenu
                    case .goal: goalKindFilterMenu
                    }
                }
            }
        }
        // all-item 모드에서만 검색 바.
        .modifier(SearchableIfAllItem(item: item, searchText: $searchText))
        // sheet/push 양쪽 모두에서 사용자 테마 보존 (NavigationLink pop 시 tint 잃는 케이스 방어).
        .appTint()
    }

    private var navigationTitle: LocalizedStringKey {
        if item != nil { return "activity_history.title.item" }
        return scope == .goal ? "activity_history.title.goal" : "activity_history.title.todo"
    }

    // MARK: - List

    @ViewBuilder
    private var listContent: some View {
        List {
            // per-item 모드에서만 header에 항목 메타.
            if let item {
                Section {
                    itemHeader(item)
                }
            }
            ForEach(groupedByMonth, id: \.monthKey) { group in
                Section(group.label) {
                    ForEach(group.rows, id: \.objectID) { rc in
                        recordRow(rc)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// 현재 활성 필터 카테고리. all-item .todo 모드 + filterCategoryID 있을 때만.
    private var activeFilterCategory: Category? {
        guard item == nil, scope == .todo, let id = filterCategoryID else { return nil }
        return categories.first(where: { $0.id == id })
    }

    /// 필터 활성 시 navigation title의 prefix 텍스트.
    /// - .todo + 카테고리: "<카테고리명> 기록"
    /// - .goal + 목표 유형: "<유형> 목표 기록"
    /// 둘 다 미적용이면 nil (기본 navigationTitle 사용).
    private var filteredNavigationTitle: String? {
        guard item == nil else { return nil }
        switch scope {
        case .todo:
            guard let cat = activeFilterCategory, let name = cat.name, !name.isEmpty else { return nil }
            return String.localizedStringWithFormat(
                NSLocalizedString("activity_history.title.todo_filter_format", comment: ""),
                name
            )
        case .goal:
            guard let kind = filterGoalKind else { return nil }
            return String.localizedStringWithFormat(
                NSLocalizedString("activity_history.title.goal_filter_format", comment: ""),
                kind.displayName
            )
        }
    }

@ViewBuilder
    private func itemHeader(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title ?? "")
                .font(.headline)
            HStack(spacing: 8) {
                if item.recurrenceRule != nil {
                    let s = item.currentStreak()
                    if s > 0 {
                        // Label은 .titleAndIcon 스타일이라 아이콘·텍스트 간격이 자동으로 넓음 →
                        // 직접 HStack(spacing: 2)로 좁게.
                        HStack(spacing: 2) {
                            Image(systemName: "flame.fill")
                            Text(verbatim: "\(s)")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                let total = item.routineHistoryRecords.count
                Text("activity_history.total.\(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func recordRow(_ rc: RoutineCompletion) -> some View {
        let isActivity = rc.item?.itemKind == .activity
        let valueRecorded = Int(rc.valueRecorded?.doubleValue ?? 0)
        let target = rc.item?.activityTargetValueInt ?? 0
        // 활동 진행 케이스: done/failed 아니면서 valueRecorded > 0.
        let isActivityProgress = isActivity && !rc.done && !rc.failed && valueRecorded > 0
        VStack(alignment: .leading, spacing: 4) {
            // all-item 모드: 항목 제목 강조. 카테고리 바: Todo는 카테고리 색, 목표는 iconColorHex.
            if item == nil, let title = rc.item?.title, !title.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let barColor = recordBarColor(for: rc) {
                        Rectangle()
                            .fill(barColor)
                            .frame(width: 3, height: 12)
                            .alignmentGuide(.firstTextBaseline) { d in d.height * 0.9 }
                    }
                    Text(verbatim: title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: recordIconName(rc: rc, isActivityProgress: isActivityProgress))
                    .foregroundStyle(recordIconColor(rc: rc, isActivityProgress: isActivityProgress))
                Text(verbatim: dateLabel(for: rc))
                    .font(.callout)
                    .foregroundStyle(.primary)
                Text(verbatim: timeLabel(for: rc))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                // 활동: 누적값/목표 표시. 그 외: 상태 라벨.
                if isActivity, target > 0 {
                    Text(verbatim: "\(valueRecorded)/\(target)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(rc.done ? Color.accentColor : .secondary)
                } else {
                    Text(recordStatusKey(rc: rc, isActivityProgress: isActivityProgress))
                        .font(.caption)
                        .foregroundStyle(rc.done ? Color.accentColor : .secondary)
                }
            }
            // 포기 사유 — 있을 때만 별도 라인.
            if let comment = rc.comment, !comment.isEmpty {
                Text(commentText(comment: comment, isDone: rc.done))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
    }

    /// 항목 제목 앞 세로 바 색 — Todo는 카테고리, 목표는 iconColorHex.
    private func recordBarColor(for rc: RoutineCompletion) -> Color? {
        guard let item = rc.item else { return nil }
        if item.itemKind.isGoal {
            guard let raw = item.iconColorHex,
                  let cc = CategoryColor(rawValue: raw) else { return nil }
            return cc.color
        }
        guard let cat = item.category,
              let raw = cat.colorHex,
              let cc = CategoryColor(rawValue: raw) else { return nil }
        return cc.color
    }

    /// RC 상태 아이콘 — done/failed/활동 진행 분기.
    /// 활동 진행: `circle.bottomhalf.filled` — 부분 채워진 원 (done의 checkmark.circle.fill, failed의 xmark.circle.fill과
    /// 같은 `.circle` 패밀리 + 절반 채워진 모양으로 "진행 중" 의미).
    private func recordIconName(rc: RoutineCompletion, isActivityProgress: Bool) -> String {
        if rc.done { return "checkmark.circle.fill" }
        if rc.failed { return "xmark.circle.fill" }
        if isActivityProgress { return "circle.bottomhalf.filled" }
        return "circle"
    }

    private func recordIconColor(rc: RoutineCompletion, isActivityProgress: Bool) -> Color {
        if rc.done { return Color.accentColor }
        if isActivityProgress { return Color.accentColor }
        return Color.secondary
    }

    private func recordStatusKey(rc: RoutineCompletion, isActivityProgress: Bool) -> LocalizedStringKey {
        if rc.done { return "activity_history.status.done" }
        if isActivityProgress { return "activity_history.status.in_progress" }
        return "activity_history.status.failed"
    }

    private func dateLabel(for rc: RoutineCompletion) -> String {
        // 표시 일자 — completedAt(instant) 우선, 없으면 date(UTC anchor) fallback.
        // completedAt은 local 자정 기준 표기 ("M월 d일 (E)").
        let f = DateFormatter()
        f.locale = Locale.current
        if let inst = rc.completedAt {
            f.setLocalizedDateFormatFromTemplate("MMMd")
            let dayStr = f.string(from: inst)
            let weekdayF = DateFormatter()
            weekdayF.locale = Locale.current
            weekdayF.setLocalizedDateFormatFromTemplate("EEE")
            return "\(dayStr) (\(weekdayF.string(from: inst)))"
        }
        if let day = rc.date {
            f.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            f.setLocalizedDateFormatFromTemplate("MMMdEEE")
            return f.string(from: day)
        }
        return ""
    }

    private func timeLabel(for rc: RoutineCompletion) -> String {
        guard let inst = rc.completedAt else { return "" }
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jm")
        return f.string(from: inst)
    }

    private func commentText(comment: String, isDone: Bool) -> String {
        if isDone { return comment }
        return String.localizedStringWithFormat(
            NSLocalizedString("activity_history.reason_format", comment: ""),
            comment
        )
    }

    // MARK: - Filter UI

    @ViewBuilder
    private var filterMenu: some View {
        Menu {
            ForEach(HistoryFilter.allCases) { f in
                Button {
                    filter = f
                } label: {
                    if filter == f {
                        Label(f.labelKey, systemImage: "checkmark")
                    } else {
                        Text(f.labelKey)
                    }
                }
            }
        } label: {
            // 상태 필터(전체/완료/포기) — completion status 관련이라 checkmark.circle 계열.
            Image(systemName: filter == .all
                  ? "checkmark.circle"
                  : "checkmark.circle.fill")
        }
    }

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
            // 카테고리 필터 — ListView/ArchiveView/TodayView와 동일 패턴 (line.3.horizontal.decrease.circle).
            Image(systemName: filterCategoryID == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }

    /// 목표 유형 필터 메뉴 — scope=.goal일 때만 노출. 전체 + 4 type(절제/활동/집중/습관).
    @ViewBuilder
    private var goalKindFilterMenu: some View {
        Menu {
            Button {
                filterGoalKind = nil
            } label: {
                if filterGoalKind == nil {
                    Label("list.filter.all", systemImage: "checkmark")
                } else {
                    Text("list.filter.all")
                }
            }
            ForEach(Self.goalKindOptions, id: \.self) { type in
                Button {
                    filterGoalKind = type
                } label: {
                    if filterGoalKind == type {
                        Label(type.displayName, systemImage: "checkmark")
                    } else {
                        Label {
                            Text(verbatim: type.displayName)
                        } icon: {
                            Image(systemName: type.goalTypeSymbolName)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: filterGoalKind == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        let hasQuery = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                       || filterCategoryID != nil
                       || filter != .all
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(hasQuery ? "activity_history.empty.filtered" : "activity_history.empty.all")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - .searchable conditional modifier (all-item 모드만)

private struct SearchableIfAllItem: ViewModifier {
    let item: Item?
    @Binding var searchText: String

    func body(content: Content) -> some View {
        if item == nil {
            content.searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                               prompt: "activity_history.search.placeholder")
        } else {
            content
        }
    }
}

#Preview("Per-item") {
    NavigationStack {
        ActivityHistoryView(item: nil)
            .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
    }
}
