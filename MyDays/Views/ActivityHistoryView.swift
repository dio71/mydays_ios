import CoreData
import SwiftUI

// MARK: - ActivityHistoryView
//
// RoutineCompletion 기반 활동 기록 화면.
// - `item: Item?` optional —
//   · item != nil: per-item 모드. 그 item의 RC만. AddItemView "전체 보기 →"에서 진입.
//   · item == nil: all-item 모드. 모든 active item의 RC. 카테고리 필터 + 검색.
// - 정렬: completedAt desc (없으면 date desc fallback).
// - Section: 월 단위 ("2026년 5월" 같은 형식).
// - 필터: 전체 / 완료만 / 포기만.
// - All-item 검색: title + notes(`#태그` 포함) substring match.

struct ActivityHistoryView: View {

    let item: Item?

    @Environment(\.managedObjectContext) private var context
    @State private var filter: HistoryFilter = .all
    @State private var filterCategoryID: UUID?
    @State private var searchText: String = ""

    // FetchRequest로 RC 직접 fetch. predicate는 item != nil이면 item만, nil이면 전체.
    // animation: .default로 row 변경 시 부드러운 transition.
    @FetchRequest private var records: FetchedResults<RoutineCompletion>

    /// all-item 모드 카테고리 필터용.
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Category.sortOrder), SortDescriptor(\Category.name)],
        animation: .default
    )
    private var categories: FetchedResults<Category>

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

    init(item: Item?) {
        self.item = item
        let predicate: NSPredicate
        if let item {
            predicate = NSPredicate(format: "item == %@ AND (done == YES OR failed == YES)", item)
        } else {
            predicate = NSPredicate(format: "item != nil AND (done == YES OR failed == YES)")
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
        records.filter { rc in
            // 상태 필터
            switch filter {
            case .all: break
            case .done: if !rc.done { return false }
            case .failed: if !rc.failed { return false }
            }
            // all-item 모드: 카테고리 + 검색
            if item == nil {
                if let catID = filterCategoryID {
                    guard rc.item?.category?.id == catID else { return false }
                }
                let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let title = rc.item?.title ?? ""
                    let notes = rc.item?.notes ?? ""
                    let q = trimmed
                    if !title.localizedCaseInsensitiveContains(q),
                       !notes.localizedCaseInsensitiveContains(q) {
                        return false
                    }
                }
            }
            return true
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
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
            if item == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    categoryFilterMenu
                }
            }
        }
        // all-item 모드에서만 검색 바.
        .modifier(SearchableIfAllItem(item: item, searchText: $searchText))
        // sheet/push 양쪽 모두에서 사용자 테마 보존 (NavigationLink pop 시 tint 잃는 케이스 방어).
        .appTint()
    }

    private var navigationTitle: LocalizedStringKey {
        item == nil ? "activity_history.title.all" : "activity_history.title.item"
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
        VStack(alignment: .leading, spacing: 4) {
            // all-item 모드: 항목 제목 — 일자/상태 라인보다 강조 (subheadline semibold .primary).
            // 어떤 일정의 기록인지 한눈에 식별되도록 일자 라인보다 굵게/크게.
            if item == nil, let title = rc.item?.title, !title.isEmpty {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: rc.done ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(rc.done ? Color.accentColor : Color.secondary)
                Text(verbatim: dateLabel(for: rc))
                    .font(.callout)
                    .foregroundStyle(.primary)
                Text(verbatim: timeLabel(for: rc))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(rc.done ? "activity_history.status.done" : "activity_history.status.failed")
                    .font(.caption)
                    .foregroundStyle(rc.done ? Color.accentColor : .secondary)
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
