import CoreData
import SwiftUI
import WidgetKit

// MARK: - NTD Widget
//
// 홈 스크린 위젯: 가장 relevant한 NTD occurrence 1개의 카운트다운 표시.
//
// 데이터 소스: App Group shared sqlite (`group.io.snapplay.MyDays/MyDays.sqlite`)
// PersistenceController.shared가 widget process에서도 동일 store를 연다.
//
// Timeline 전략: entry는 transition 시점에만 새로 발급하고, 카운트다운 자체는
// SwiftUI `Text(timerInterval:countsDown:)`이 OS-side로 매초 자동 갱신.
// 따라서 entry 수가 적어 WidgetKit 60-entry 한계와 무관.
//
// 갱신 트리거:
//   - 다음 transition instant (scheduled→inProgress, inProgress→ended)에서 reload
//   - 또는 30분 후 (예: relevant NTD 없을 때 새로 들어왔는지 재확인)

// MARK: Snapshot — NSManagedObject를 widget process에 안전하게 전달하기 위한 값 타입.
// NTD/Todo/Routine 통합. kind + isRoutine + priority + state로 식별.

struct ItemSnapshot: Equatable {
    let kind: ItemKind             // .notTodo (NTD) / .todo
    let isRoutine: Bool             // recurrenceRule != nil
    let title: String
    let priority: Priority          // 정렬 1순위 (high → none)
    let state: DisplayState
    let startInstant: Date
    /// nil이면 끝 시각이 정의되지 않음:
    /// - NTD inProgress: 한계까지 진행 중 → countup from startInstant
    /// - untimed: 시간 미설정 → 카운트다운/카운트업 X, "오늘" 라벨
    let endInstant: Date?
    /// 카테고리 아이콘 SF Symbol 이름 (Category.iconName 그대로). 미설정 시 nil → fallback 아이콘.
    let categoryIconName: String?
    /// 카테고리 색상 rawValue (CategoryColor.rawValue, 예: "red"). 미설정 시 nil → 앱 tint fallback.
    let categoryColorHex: String?

    /// 표시 상태. NTDState보다 generic — Todo의 overdue/untimed까지 표현.
    enum DisplayState: Equatable {
        case scheduled     // 시작 전 (시간 명시)
        case inProgress    // 진행 중 (시간 명시 + 종료 전, 또는 NTD 한계까지)
        case overdue       // Todo 마감 시각 지남 (NTD는 자동 완료라 도달 X)
        case untimed       // 시간 미설정 — 오늘 일정/루틴이지만 시각 없음
    }
}

// MARK: TimelineEntry

/// "오늘 활동" 종류별 active 개수. 위젯에 일부만 표시되니 전체 visibility 보조용.
/// - ntdCount: relevant occurrence가 있고 ended 아님 (진행 중 + 예정)
/// - todoCount: 1회성 Todo 중 오늘 todoSection 매칭
/// - routineCount: 반복 Todo 중 오늘 occurrence + 미체크
struct ActivitySummary: Equatable {
    let ntdCount: Int
    let todoCount: Int
    let routineCount: Int

    static let empty = ActivitySummary(ntdCount: 0, todoCount: 0, routineCount: 0)
}

struct NTDEntry: TimelineEntry {
    let date: Date
    let snapshots: [ItemSnapshot]  // 비어 있으면 표시할 항목 없음 (NTD/Todo/Routine 통합)
    let summary: ActivitySummary
}

// MARK: Provider
//
// 정렬 우선순위 (사용자 정의):
//   1. 진행 중 + 목표시간 있음 → endInstant(종료 예정) 이른 순
//   2. 예정(scheduled) → startInstant 이른 순
//   3. 진행 중 + 목표시간 없음 (한계까지) → 가장 마지막
// → 종료 가까운 것 / 곧 시작할 것 / 한계 진행 중 순으로 노출.
//
// Provider는 최대 maxSnapshotCount(3)개를 미리 가져오고, View가 family에 따라 prefix.

struct NTDProvider: TimelineProvider {

    /// 최대 10개까지 fetch. View가 family·항목 종류별 높이에 따라 들어가는 만큼만 렌더.
    /// NTD/할일 box 높이가 달라 family당 고정 개수가 아닌 budget 기반 fit으로 처리.
    private static let maxSnapshotCount = 10

    func placeholder(in context: Context) -> NTDEntry {
        // iOS가 placeholder mode (loading)에서도 우리 layout이 보이도록 real data로 채움.
        // RedactionReasons.placeholder는 자동 적용되어 text가 skeleton 회색 처리되지만
        // view 구조/배경/icon 위치는 정확히 유지됨 — 빈 entry보다 시각적 일관성 우수.
        let now = Date()
        let items = Self.fetchActiveItems()
        return NTDEntry(
            date: now,
            snapshots: Self.makeSnapshots(items: items, now: now, limit: Self.maxSnapshotCount),
            summary: Self.computeSummary(items: items, now: now)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NTDEntry) -> Void) {
        let now = Date()
        let items = Self.fetchActiveItems()
        let snaps = Self.makeSnapshots(items: items, now: now, limit: Self.maxSnapshotCount)
        let summary = Self.computeSummary(items: items, now: now)
        completion(NTDEntry(date: now, snapshots: snaps, summary: summary))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NTDEntry>) -> Void) {
        let now = Date()
        let items = Self.fetchActiveItems()

        // Lock widget과 동일 tiered granularity:
        //   > 3h: 30min step / 3h~1h: 10min step / 1h~20m: 5min step / <20m: 1min step / 미설정: 1h step
        // 멀리 있는 시점은 정밀도 낮춰도 무관, 가까운 시점만 빈번히 갱신해 budget 안에서 정확도 확보.
        let transitions = Self.transitionInstants(items: items, after: now)
        let horizon = now.addingTimeInterval(6 * 60 * 60)
        var dates: Set<Date> = []
        var t = now
        while t <= horizon {
            dates.insert(t)
            let nextT = transitions.first { $0 > t }
            let step: TimeInterval
            if let nt = nextT {
                let ttt = nt.timeIntervalSince(t)
                if ttt > 3 * 60 * 60 { step = 30 * 60 }
                else if ttt > 60 * 60 { step = 10 * 60 }
                else if ttt > 20 * 60 { step = 5 * 60 }
                else { step = 60 }
            } else {
                step = 60 * 60  // transition 없음 → 1시간 step
            }
            let next = t.addingTimeInterval(step)
            if let nt = nextT, nt > t && nt < next {
                dates.insert(nt)
            }
            t = next
        }
        let entries: [NTDEntry] = dates.sorted().map { date in
            NTDEntry(
                date: date,
                snapshots: Self.makeSnapshots(items: items, now: date, limit: Self.maxSnapshotCount),
                summary: Self.computeSummary(items: items, now: date)
            )
        }
        let reloadAt = (entries.last?.date ?? now).addingTimeInterval(60)
        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }

    // MARK: - 데이터 fetch

    /// 모든 active(status=0) 항목을 fetch — NTD 뿐 아니라 Todo/루틴 카운트도 같은 fetch 결과로 처리.
    /// kind 필터는 호출 측에서 분기.
    private static func fetchActiveItems() -> [Item] {
        let context = PersistenceController.shared.viewContext
        // Multi-process Core Data — main app이 sqlite에 save해도 widget process의 row cache는 stale.
        // refresh로 캐시된 객체를 fault 처리해 다음 access 시 store에서 다시 읽도록 강제.
        context.refreshAllObjects()
        let request: NSFetchRequest<Item> = Item.fetchRequest()
        request.predicate = NSPredicate(format: "status == 0")
        return (try? context.fetch(request)) ?? []
    }

    /// 주어진 `now` 기준으로 NTD/Todo/Routine snapshot 목록을 만들어 정렬 후 limit개 반환.
    private static func makeSnapshots(items: [Item], now: Date, limit: Int) -> [ItemSnapshot] {
        let today: Date = .todayCalendarAnchor
        var candidates: [ItemSnapshot] = []

        for item in items {
            if let snap = Self.snapshot(for: item, now: now, today: today) {
                candidates.append(snap)
            }
        }

        candidates.sort { a, b in
            if a.kindOrder != b.kindOrder { return a.kindOrder < b.kindOrder }
            if a.priorityOrder != b.priorityOrder { return a.priorityOrder < b.priorityOrder }
            return a.sortAnchor < b.sortAnchor
        }
        return Array(candidates.prefix(limit))
    }

    /// 한 항목에서 표시 가능 snapshot을 생성. 표시 안 할 항목(완료/오늘 occurrence 없음 등)은 nil.
    private static func snapshot(for item: Item, now: Date, today: Date) -> ItemSnapshot? {
        switch item.itemKind {
        case .notTodo:
            return ntdSnapshot(item: item, now: now)
        case .todo:
            if item.recurrenceRule != nil {
                return routineSnapshot(item: item, now: now, today: today)
            }
            return todoSnapshot(item: item, now: now, today: today)
        case .activity:
            // TODO: 활동 위젯 snapshot — Phase B/C. 현재는 미노출.
            return nil
        case .focus:
            // TODO: 집중 위젯 snapshot — Phase D. 현재는 미노출.
            return nil
        case .habit:
            // 습관은 routine Todo와 동일 패턴이라 routineSnapshot 재활용 가능.
            // Phase A 위젯 미노출 — 다음 phase에 통합.
            return nil
        }
    }

    private static func ntdSnapshot(item: Item, now: Date) -> ItemSnapshot? {
        // 오늘 포기 occurrence가 있는 NTD는 위젯에서 제외 — 사용자가 포기한 항목이 다음 occurrence로
        // 미루어져 노출되는 어색함 회피.
        let today = Date.todayCalendarAnchor
        if let record = item.routineRecord(on: today), record.failed {
            return nil
        }
        guard let occ = item.ntdRelevantOccurrenceDate(at: now),
              let ntdState = item.ntdState(on: occ, now: now),
              ntdState != .ended,
              let start = item.ntdStartInstant(on: occ)
        else { return nil }
        // 오늘보다 미래 occurrence(예: 3일 뒤 시작)는 위젯에서 제외 — "오늘 일정" 범위.
        let occDay = Calendar.gmt.startOfDay(for: occ)
        if occDay > today { return nil }
        let end = item.ntdEndInstant(on: occ)
        let display: ItemSnapshot.DisplayState
        switch ntdState {
        case .scheduled:  display = .scheduled
        case .inProgress: display = .inProgress  // end nil이면 한계까지 — countdownText에서 countup 분기
        case .ended:      return nil  // 안전망, 위에서 이미 걸러짐
        }
        return ItemSnapshot(
            kind: .notTodo,
            isRoutine: item.recurrenceRule != nil,
            title: item.title ?? "",
            priority: item.itemPriority,
            state: display,
            startInstant: start,
            endInstant: end,
            categoryIconName: item.category?.iconName,
            categoryColorHex: item.category?.colorHex
        )
    }

    /// 1회성 Todo. todoSection 매칭(오늘 표시 대상) 항목만 snapshot으로.
    /// 시작일이 오늘보다 미래(예: 3일 뒤 시작)면 위젯에서 제외 — "오늘 일정" 범위 한정.
    private static func todoSnapshot(item: Item, now: Date, today: Date) -> ItemSnapshot? {
        guard item.todoSection(on: today, now: now) != nil else { return nil }
        guard let start = item.effectiveStartInstant else { return nil }
        let end = item.effectiveDueInstant
        let startDay = Calendar.gmt.startOfDay(for: item.startDate ?? today)
        if startDay > today { return nil }
        let display = todoDisplayState(start: start, end: end, hasExplicitTime: item.hasExplicitTime, now: now)
        return ItemSnapshot(
            kind: .todo,
            isRoutine: false,
            title: item.title ?? "",
            priority: item.itemPriority,
            state: display,
            startInstant: start,
            endInstant: end,
            categoryIconName: item.category?.iconName,
            categoryColorHex: item.category?.colorHex
        )
    }

    /// 반복 Todo (루틴). 오늘 occurrence + 미체크인 경우 snapshot 생성.
    private static func routineSnapshot(item: Item, now: Date, today: Date) -> ItemSnapshot? {
        guard let rule = item.recurrenceRule,
              rule.occurs(on: today, startDate: item.startDate, endDate: item.recurrenceEndDate),
              !item.hasRoutineRecord(on: today)
        else { return nil }
        guard let start = Item.localInstant(fromCalendarDate: today, hour: item.startHourInt) else { return nil }
        let span = item.spanDays
        let endDay = Calendar.gmt.date(byAdding: .day, value: span, to: today) ?? today
        let end = Item.localInstant(fromCalendarDate: endDay, hour: item.dueHourInt)
        let display = todoDisplayState(start: start, end: end, hasExplicitTime: item.hasExplicitTime, now: now)
        return ItemSnapshot(
            kind: .todo,
            isRoutine: true,
            title: item.title ?? "",
            priority: item.itemPriority,
            state: display,
            startInstant: start,
            endInstant: end,
            categoryIconName: item.category?.iconName,
            categoryColorHex: item.category?.colorHex
        )
    }

    /// Todo/Routine 공통 display state 결정 — 시간 미설정이면 .untimed, 그 외 instant 비교.
    private static func todoDisplayState(start: Date, end: Date?, hasExplicitTime: Bool, now: Date) -> ItemSnapshot.DisplayState {
        if !hasExplicitTime { return .untimed }
        if now < start { return .scheduled }
        if let end = end, now >= end { return .overdue }
        return .inProgress
    }

    /// 오늘 활동 종류별 카운트 — snapshot 가능한 항목과 일관 (포기 NTD 제외 등 동일 필터).
    private static func computeSummary(items: [Item], now: Date) -> ActivitySummary {
        let today: Date = .todayCalendarAnchor
        let snapshots = items.compactMap { Self.snapshot(for: $0, now: now, today: today) }
        let ntd = snapshots.filter { $0.kind == .notTodo }.count
        let todo = snapshots.filter { $0.kind == .todo && !$0.isRoutine }.count
        let routine = snapshots.filter { $0.kind == .todo && $0.isRoutine }.count
        return ActivitySummary(ntdCount: ntd, todoCount: todo, routineCount: routine)
    }

    /// items 전체에서 `now` 이후의 모든 transition instant (시작·종료) 수집해 시간 ascending으로 반환.
    /// 표시 우선순위가 낮아 limit에서 빠진 NTD의 transition도 포함 — 그 시점에 후보 reshuffle 가능.
    /// items 전체에서 `now` 이후 모든 transition instant (시작/종료 + 그 5분 전) 수집.
    /// NTD/Todo/Routine 모두 동일 패턴 — 각 항목의 적용 occurrence start/end instant.
    private static func transitionInstants(items: [Item], after now: Date) -> [Date] {
        let today: Date = .todayCalendarAnchor
        var set = Set<TimeInterval>()
        for item in items {
            for instant in instantsForTransition(item: item, now: now, today: today) {
                if instant > now { set.insert(instant.timeIntervalSince1970) }
                let pre = instant.addingTimeInterval(-Self.fineGrainedThreshold)
                if pre > now { set.insert(pre.timeIntervalSince1970) }
            }
        }
        return set.sorted().map { Date(timeIntervalSince1970: $0) }
    }

    private static func instantsForTransition(item: Item, now: Date, today: Date) -> [Date] {
        switch item.itemKind {
        case .notTodo:
            guard let occ = item.ntdRelevantOccurrenceDate(at: now) else { return [] }
            return [item.ntdStartInstant(on: occ), item.ntdEndInstant(on: occ)].compactMap { $0 }
        case .todo:
            if let rule = item.recurrenceRule {
                guard rule.occurs(on: today, startDate: item.startDate, endDate: item.recurrenceEndDate) else { return [] }
                let start = Item.localInstant(fromCalendarDate: today, hour: item.startHourInt)
                let span = item.spanDays
                let endDay = Calendar.gmt.date(byAdding: .day, value: span, to: today) ?? today
                let end = Item.localInstant(fromCalendarDate: endDay, hour: item.dueHourInt)
                return [start, end].compactMap { $0 }
            }
            return [item.effectiveStartInstant, item.effectiveDueInstant].compactMap { $0 }
        case .activity, .focus, .habit:
            // Phase A 위젯 미노출 — 향후 단계에서 추가.
            return []
        }
    }

    /// 카운트다운이 초 단위로 표시되는 임계 (초). 이 이내면 1초 schedule + mm:ss 포맷.
    static let fineGrainedThreshold: TimeInterval = 300  // 5분
}

// internal — lock screen widget(MyDaysNTDLockWidget) 등 같은 target의 다른 파일에서 정렬 helper 재사용.
extension ItemSnapshot {
    /// 1순위: kind 그룹 — NTD(0) → Todo(1).
    var kindOrder: Int { kind == .notTodo ? 0 : 1 }

    /// 2순위: priority — high(0) → medium(1) → low(2) → none(3).
    var priorityOrder: Int {
        switch priority {
        case .high:   return 0
        case .medium: return 1
        case .low:    return 2
        case .none:   return 3
        }
    }

    /// 3순위: 기준시간 ascending (가장 가까운 시간 먼저).
    /// - 진행 중 / 마감 지남: 종료일의 종료시각 (없으면 시작일+24h, NTD 한계까지)
    /// - 예정: 시작일의 시작시각
    /// - 시간 없음: 시작일+24h (시간 있는 항목 다음으로)
    var sortAnchor: TimeInterval {
        switch state {
        case .scheduled:
            return startInstant.timeIntervalSince1970
        case .inProgress, .overdue:
            if let end = endInstant { return end.timeIntervalSince1970 }
            return startInstant.addingTimeInterval(24 * 3600).timeIntervalSince1970
        case .untimed:
            return startInstant.addingTimeInterval(24 * 3600).timeIntervalSince1970
        }
    }
}

// MARK: - Views

struct MyDaysWidgetEntryView: View {

    @Environment(\.widgetFamily) private var family
    let entry: NTDEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                mediumLayout(snapshots: entry.snapshots)
            default:
                smallLayout(snapshots: entry.snapshots)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: 항목 fit 계산 — 항목 종류별 높이가 다르므로 budget(pt) 안에 들어가는 prefix만 렌더.
    // ViewThatFits는 variant마다 SwiftUI layout pass가 돌아 부담 크고, 위젯 process 메모리 한계에
    // 민감하므로 deterministic 높이 추정으로 처리.
    //
    // 추정 근거:
    //   - widget content 영역(containerBackground 내부)은 iPhone small/medium에서 ~142pt
    //   - dateLine(font 34) + summaryLine(caption) + 내부 spacing 합산 ≈ 64pt → headerHeight
    //   - itemBox 내부: VStack spacing 2 + vertical padding 6 + caption 라인.
    //     Todo는 1줄 (caption ~16pt) → 22pt. NTD는 2줄 (caption + caption2) → 36pt.
    //   - VStack(spacing: 6)에서 항목 간 6pt.

    private static let widgetContentHeight: CGFloat = 142
    private static let headerHeight: CGFloat = 64
    private static let itemSpacing: CGFloat = 6
    private static let todoItemHeight: CGFloat = 22
    private static let ntdItemHeight: CGFloat = 36

    private static func itemHeight(_ snap: ItemSnapshot) -> CGFloat {
        snap.kind == .notTodo ? ntdItemHeight : todoItemHeight
    }

    /// items 시작점부터 누적 높이가 budget 이하인 prefix 개수 반환.
    private static func fitCount(in budget: CGFloat, items: ArraySlice<ItemSnapshot>) -> Int {
        var used: CGFloat = 0
        var count = 0
        for snap in items {
            let h = itemHeight(snap)
            let need = count == 0 ? h : (used + itemSpacing + h)
            if need > budget { break }
            used = need
            count += 1
        }
        return count
    }

    /// Medium: 왼쪽(header 포함) 먼저 채우고 남은 항목은 오른쪽으로. 우측 budget 초과분은 잘림.
    private static func splitForMedium(snapshots: [ItemSnapshot]) -> (left: [ItemSnapshot], right: [ItemSnapshot]) {
        let leftBudget = widgetContentHeight - headerHeight
        let leftCount = fitCount(in: leftBudget, items: snapshots[...])
        let rightStart = leftCount
        let rightCount = fitCount(in: widgetContentHeight, items: snapshots[rightStart...])
        return (
            left: Array(snapshots[0..<leftCount]),
            right: Array(snapshots[rightStart..<(rightStart + rightCount)])
        )
    }

    /// Small: header 아래에 들어가는 항목 수.
    private static func smallFitCount(snapshots: [ItemSnapshot]) -> Int {
        fitCount(in: widgetContentHeight - headerHeight, items: snapshots[...])
    }

    /// 캘린더 풍 header: 큰 날짜 숫자 + 요일.
    /// 예: "26" + "화요일" / "Tuesday". Apple 캘린더 위젯의 가벼운 weight 패턴.
    private var dateLine: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(verbatim: Self.formatDay(entry.date))
                .font(.system(size: 34))
                .foregroundStyle(.primary)
            Text(verbatim: Self.formatWeekdayFull(entry.date))
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .lineLimit(1)
    }

    /// "절제 N · 할일 M · 루틴 X" 한 줄 요약.
    private var summaryLine: some View {
        Text(verbatim: Self.summaryText(entry.summary))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// `d` 형식: "26".
    private static func formatDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "d"
        return f.string(from: date)
    }

    /// "EEEE" template: ko "화요일", en "Tuesday".
    private static func formatWeekdayFull(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f.string(from: date)
    }

    private static func summaryText(_ s: ActivitySummary) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("widget.summary.format", comment: ""),
            s.ntdCount,
            s.todoCount,
            s.routineCount
        )
    }

    // MARK: 항목 캡슐 — 전체 항목(icon + title + state + countdown)이 하나의 box.
    // Apple 캘린더 위젯 패턴 — 각 일정이 highlight 박스로 묶임.

    private func itemBox(snap: ItemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: iconName(for: snap))
                    .font(.caption)
                    .foregroundStyle(iconColor(for: snap))
                Text(verbatim: snap.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // 시간 표시는 NTD만 (할일은 아이콘 + 제목으로 충분).
            if snap.kind == .notTodo {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Spacer(minLength: 0)
                    stateLabel(for: snap)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    countdownText(for: snap)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        // Text(date, style: .relative)는 최대 폭으로 reserve해 좌측 정렬처럼 보일 수 있음.
                        // multilineTextAlignment(.trailing) + frame trailing alignment로 강제 우측 정렬.
                        .multilineTextAlignment(.trailing)
                        .frame(alignment: .trailing)
                }
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
        )
    }

    // MARK: Small — 캘린더 header + budget 안에 들어가는 만큼 항목 캡슐 (Todo·NTD 혼합 가능)

    private func smallLayout(snapshots: [ItemSnapshot]) -> some View {
        let count = Self.smallFitCount(snapshots: snapshots)
        return VStack(alignment: .leading, spacing: Self.itemSpacing) {
            dateLine
            summaryLine
            ForEach(Array(snapshots.prefix(count).enumerated()), id: \.offset) { _, snap in
                itemBox(snap: snap)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Medium — 좌측(header 포함) 먼저 채우고 남은 항목은 우측. budget 초과분은 잘림.

    private func mediumLayout(snapshots: [ItemSnapshot]) -> some View {
        let split = Self.splitForMedium(snapshots: snapshots)
        return HStack(alignment: .top, spacing: 12) {
            leftHalf(snapshots: split.left)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            rightHalf(snapshots: split.right)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func leftHalf(snapshots: [ItemSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            dateLine
            summaryLine
            ForEach(Array(snapshots.enumerated()), id: \.offset) { _, snap in
                itemBox(snap: snap)
            }
            Spacer(minLength: 0)
        }
    }

    private func rightHalf(snapshots: [ItemSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            ForEach(Array(snapshots.enumerated()), id: \.offset) { _, snap in
                itemBox(snap: snap)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("widget.ntd.empty")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            summaryLine
        }
    }

    // MARK: helpers

    /// 카운트다운 / 경과 / 마감지남 / 시간 미설정 텍스트.
    /// - 1분 이상: 미리 계산된 단위 명시 포맷 ("20분" / "16시간 30분" / "5일 3시간"). Provider tiered entries로 매분 갱신.
    /// - 1분 이내 + target 있음: `Text(timerInterval:countsDown:showsHours:false)` — 시스템 timer로 매초 tick ("0:45" → "0:44"...). Widget budget 소비 X.
    /// - inProgress + 종료 없음(한계까지 count up): 분 단위 (target 없어 timer 사용 불가).
    @ViewBuilder
    private func countdownText(for snap: ItemSnapshot) -> some View {
        switch snap.state {
        case .scheduled:
            countdownInner(target: snap.startInstant, snap: snap)
        case .inProgress:
            if let end = snap.endInstant {
                countdownInner(target: end, snap: snap)
            } else {
                // 한계까지 count up — timer 사용 불가, 분 단위 표시.
                Text(verbatim: MyDaysNTDLockWidgetEntryView.formatDuration(for: snap, now: entry.date))
            }
        case .overdue, .untimed:
            EmptyView()
        }
    }

    /// target까지 남은 시간에 따라 표시 분기.
    /// 1분 이내 → 시스템 timer (초 단위 live), 그 외 → 분 단위 pre-computed.
    @ViewBuilder
    private func countdownInner(target: Date, snap: ItemSnapshot) -> some View {
        let remaining = target.timeIntervalSince(entry.date)
        if remaining > 0 && remaining <= 60 {
            Text(timerInterval: entry.date...target, countsDown: true, showsHours: false)
        } else {
            Text(verbatim: MyDaysNTDLockWidgetEntryView.formatDuration(for: snap, now: entry.date))
        }
    }

    private func stateLabel(for snap: ItemSnapshot) -> Text {
        switch snap.state {
        case .scheduled:  return Text("widget.state.scheduled")  // 시작까지
        case .inProgress:
            return snap.endInstant != nil
                ? Text("widget.state.remaining")  // 종료까지
                : Text("widget.state.elapsed")    // 경과 — NTD 한계까지
        case .overdue:    return Text("widget.state.overdue")    // 지남
        case .untimed:    return Text("widget.state.today")      // 오늘 (시간 미설정)
        }
    }

    /// 아이콘 symbol 이름.
    /// 카테고리 설정 시: 카테고리 아이콘 (CategoryIcon symbol 그대로).
    /// 미설정 시: kind 별 fallback — NTD=clock / Todo=circle.
    private func iconName(for snap: ItemSnapshot) -> String {
        if let name = snap.categoryIconName, !name.isEmpty { return name }
        return snap.kind == .notTodo ? "clock" : "circle"
    }

    /// 아이콘 색상 — 모든 항목 통일 앱 tint.
    /// 카테고리별 색상을 쓰면 여러 항목이 무지개처럼 보여 시각 균형 깨짐 → 색은 앱 tint로 통일,
    /// 카테고리 구분은 symbol 자체로만 표현 (iconName).
    /// 위젯 process는 main app의 `.tint()` 환경을 못 받아 `Color.accentColor`가 시스템 default(blue)로
    /// fallback되므로 App Group 공유 UserDefaults에서 직접 lookup.
    private func iconColor(for snap: ItemSnapshot) -> Color {
        TintPreset.currentColor
    }

    /// row 카운트다운 색 — state 무관 .primary 통일.
    private func rowAccentColor(for snap: ItemSnapshot) -> Color { .primary }
}

// MARK: - Widget Configuration

struct MyDaysWidget: Widget {
    let kind: String = "MyDaysWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NTDProvider()) { entry in
            MyDaysWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(Text("widget.ntd.display_name"))
        .description(Text("widget.ntd.description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Preview

private let previewSummary = ActivitySummary(ntdCount: 4, todoCount: 5, routineCount: 2)

private let previewSnapshots: [ItemSnapshot] = [
    ItemSnapshot(
        kind: .notTodo, isRoutine: false,
        title: "16시간 단식",
        priority: .high, state: .inProgress,
        startInstant: .now.addingTimeInterval(-3600),
        endInstant: .now.addingTimeInterval(13 * 3600),
        categoryIconName: nil, categoryColorHex: nil
    ),
    ItemSnapshot(
        kind: .notTodo, isRoutine: true,
        title: "디저트 끊기",
        priority: .medium, state: .scheduled,
        startInstant: .now.addingTimeInterval(2 * 3600),
        endInstant: .now.addingTimeInterval(26 * 3600),
        categoryIconName: nil, categoryColorHex: nil
    ),
    ItemSnapshot(
        kind: .todo, isRoutine: false,
        title: "보일러 점검",
        priority: .high, state: .scheduled,
        startInstant: .now.addingTimeInterval(3 * 3600),
        endInstant: .now.addingTimeInterval(4 * 3600),
        categoryIconName: nil, categoryColorHex: nil
    ),
    ItemSnapshot(
        kind: .todo, isRoutine: true,
        title: "물 마시기",
        priority: .none, state: .untimed,
        startInstant: .now,
        endInstant: nil,
        categoryIconName: nil, categoryColorHex: nil
    ),
    ItemSnapshot(
        kind: .todo, isRoutine: false,
        title: "리포트 마감",
        priority: .medium, state: .overdue,
        startInstant: .now.addingTimeInterval(-7200),
        endInstant: .now.addingTimeInterval(-1800),
        categoryIconName: nil, categoryColorHex: nil
    )
]

#Preview(as: .systemSmall) {
    MyDaysWidget()
} timeline: {
    NTDEntry(date: .now, snapshots: previewSnapshots, summary: previewSummary)
}

#Preview(as: .systemMedium) {
    MyDaysWidget()
} timeline: {
    NTDEntry(date: .now, snapshots: previewSnapshots, summary: previewSummary)
}
