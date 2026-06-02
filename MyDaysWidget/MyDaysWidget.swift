import CoreData
import SwiftUI
import WidgetKit

// MARK: - Home Widget (Small / Medium)
//
// Redesign (2026-06-01):
// - 시간 정보(카운트다운/시계) 모두 제거 — glance 시각에 집중.
// - 목표(절제/활동/집중/습관) 4-type 통합 + 할일을 동일 row 폭으로 나열.
// - Row 형태:
//     - 목표: (아이콘) [────── 진행바 안에 타이틀 ──────]
//     - 할일: (카테고리 아이콘) 타이틀
// - 우상단 카운트 박스: (target) 미완료/전체 / (checkmark.circle) 미완료/전체.
// - 정렬: group(목표→할일) → bucket(진행중→진행예정→종료지난) → sortAnchor.
// - 종료지난 항목도 우선순위 끝에서 노출 — 공간 부족 시 자연 잘림.
// - Reload tier: 시간 라벨 없어 30~60분 step으로 충분. transition instant만 강제 entry.
//
// 데이터 소스: App Group shared sqlite (`group.io.snapplay.MyDays/MyDays.sqlite`)

// MARK: - StatusBucket

/// 정렬·표시용 상태 bucket. type 무관 통합 분류.
enum StatusBucket: Int, Comparable {
    case ongoing = 0    // 진행중
    case scheduled = 1  // 진행예정
    case past = 2       // 종료지난

    static func < (a: StatusBucket, b: StatusBucket) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - ItemSnapshot
//
// NSManagedObject를 widget process에 전달하기 위한 값 타입.
// 4-type 목표 + 할일 통합. 기존 ItemSnapshot에서 시간 정보 제거 + progress 통합.

struct ItemSnapshot: Equatable, Identifiable {
    let id: String                 // ForEach용 — objectID + 부가 키
    let kind: ItemKind
    let title: String
    let bucket: StatusBucket
    /// 0~1 진행률. 목표 type에서 의미 있음. 할일은 0 (사용 안 함).
    /// 습관: 미체크=0, 체크=1 (binary). 일관성 위해 다른 목표와 같은 capsule 사용.
    let progress: Double
    /// 같은 bucket 안에서 정렬 기준 instant. 진행중=종료 가까운 순, 예정=시작 빠른 순, 지남=종료/완료 instant.
    let sortAnchor: Date
    /// SF Symbol 이름 (이미 resolved). 목표=`Item.iconName` (GoalIcon symbol) / 할일=카테고리 아이콘 or fallback.
    let iconName: String
    /// 색상 rawValue (CategoryColor: "red", "blue" 등). nil이면 위젯이 앱 tint로 fallback.
    let iconColorHex: String?

    var isGoal: Bool { kind != .todo }

    /// group order — 목표(0) → 할일(1).
    var groupOrder: Int { isGoal ? 0 : 1 }
}

// MARK: - Counts (우상단 박스)

struct ItemCounts: Equatable {
    let goalActive: Int      // 진행중+진행예정 (미완료) 목표
    let goalTotal: Int       // 오늘 노출 가능 전체 목표 (past 포함)
    let todoActive: Int
    let todoTotal: Int

    static let empty = ItemCounts(goalActive: 0, goalTotal: 0, todoActive: 0, todoTotal: 0)
}

// MARK: - TimelineEntry

struct MyDaysHomeEntry: TimelineEntry {
    let date: Date
    let snapshots: [ItemSnapshot]
    let counts: ItemCounts
}

// MARK: - Provider

struct MyDaysHomeProvider: TimelineProvider {

    /// 위젯 최대 노출 가능 수. View가 family·실제 공간에 맞춰 prefix.
    private static let maxSnapshotCount: Int = 16

    func placeholder(in context: Context) -> MyDaysHomeEntry {
        let now = Date()
        let items = Self.fetchActiveItems()
        return Self.makeEntry(items: items, now: now)
    }

    func getSnapshot(in context: Context, completion: @escaping (MyDaysHomeEntry) -> Void) {
        let now = Date()
        let items = Self.fetchActiveItems()
        completion(Self.makeEntry(items: items, now: now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MyDaysHomeEntry>) -> Void) {
        let now = Date()
        let items = Self.fetchActiveItems()

        // Adaptive tier — 시간 라벨 없어 budget spare. 진행바 정밀도 위주:
        //   > 1h: 60min step / 20m~1h: 10min step / 5m~20m: 5min step / <5m: 1min step / 미설정: 60min step.
        // horizon: 6h — 한 timeline의 lookahead 범위. transition은 강제 entry.
        let transitions = Self.transitionInstants(items: items, after: now)
        let horizon = now.addingTimeInterval(6 * 60 * 60)
        var dates: Set<Date> = [now]
        var t = now
        while t <= horizon {
            let nextT = transitions.first { $0 > t }
            let step: TimeInterval
            if let nt = nextT {
                let ttt = nt.timeIntervalSince(t)
                if ttt > 60 * 60 { step = 60 * 60 }
                else if ttt > 20 * 60 { step = 10 * 60 }
                else if ttt > 5 * 60 { step = 5 * 60 }
                else { step = 60 }
            } else {
                step = 60 * 60
            }
            let next = t.addingTimeInterval(step)
            if let nt = nextT, nt > t && nt < next {
                dates.insert(nt)
            }
            t = next
            dates.insert(t)
        }
        let entries: [MyDaysHomeEntry] = dates.sorted().map { date in
            Self.makeEntry(items: items, now: date)
        }
        let reloadAt = (entries.last?.date ?? now).addingTimeInterval(60)
        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }

    // MARK: - Entry 조립

    private static func makeEntry(items: [Item], now: Date) -> MyDaysHomeEntry {
        let snaps = makeSnapshots(items: items, now: now, limit: maxSnapshotCount)
        let counts = computeCounts(items: items, now: now)
        return MyDaysHomeEntry(date: now, snapshots: snaps, counts: counts)
    }

    // MARK: - Fetch

    /// status != deleted + isSomeday 제외 항목.
    /// - done(status=1)/failed(status=3)도 fetch — "종료지난" bucket 노출에 필요.
    /// - **isSomeday (보관함) 제외** — 보관함 항목은 일정 미정 inbox라 위젯 "오늘" 범위 밖.
    /// - fetch는 status·deleted만 거르고 isSomeday는 메모리 필터로 처리 — Core Data Boolean optional의
    ///   NULL semantics 때문에 SQL 단의 `isSomeday != YES`가 nil row를 포착 못 하는 케이스 회피.
    static func fetchActiveItems() -> [Item] {
        let context = PersistenceController.shared.viewContext
        // Multi-process Core Data — main app save 결과를 widget process 캐시에 반영.
        context.refreshAllObjects()
        let request: NSFetchRequest<Item> = Item.fetchRequest()
        request.predicate = NSPredicate(format: "status != %d", Status.deleted.rawValue)
        let raw = (try? context.fetch(request)) ?? []
        return raw.filter { !$0.isSomeday }
    }

    // MARK: - Snapshot 생성

    static func makeSnapshots(items: [Item], now: Date, limit: Int) -> [ItemSnapshot] {
        let today: Date = .todayCalendarAnchor
        var snaps: [ItemSnapshot] = []
        for item in items {
            // past(완료/취소/만료) 항목은 row 표시에서 제외. 카운트(computeCounts)는 별도라 영향 X.
            if let s = snapshot(for: item, now: now, today: today), s.bucket != .past {
                snaps.append(s)
            }
        }
        snaps.sort { a, b in
            if a.groupOrder != b.groupOrder { return a.groupOrder < b.groupOrder }
            if a.bucket != b.bucket { return a.bucket < b.bucket }
            return a.sortAnchor < b.sortAnchor
        }
        return Array(snaps.prefix(limit))
    }

    /// 한 항목에서 표시 가능 snapshot 생성. 표시 안 함이면 nil.
    static func snapshot(for item: Item, now: Date, today: Date) -> ItemSnapshot? {
        guard let cls = classify(item: item, now: now, today: today) else { return nil }
        let progress = computeProgress(for: item, today: today, now: now, bucket: cls.bucket)
        return ItemSnapshot(
            id: snapshotID(for: item, occurrenceKey: cls.anchor),
            kind: item.itemKind,
            title: item.title ?? "",
            bucket: cls.bucket,
            progress: progress,
            sortAnchor: cls.anchor,
            iconName: resolveIcon(for: item),
            iconColorHex: resolveColorHex(for: item)
        )
    }

    private static func snapshotID(for item: Item, occurrenceKey: Date) -> String {
        "\(item.objectID.uriRepresentation().absoluteString)#\(Int(occurrenceKey.timeIntervalSince1970))"
    }

    // MARK: - 분류 (bucket + sortAnchor)

    /// item별 status bucket과 정렬 anchor instant 결정.
    /// `nil` = 위젯 노출 대상 아님 (예: 미래 일정, 오늘 occurrence 없음).
    private static func classify(item: Item, now: Date, today: Date) -> (bucket: StatusBucket, anchor: Date)? {
        switch item.itemKind {
        case .notTodo:    return classifyNTD(item, now: now, today: today)
        case .activity:   return classifyActivity(item, now: now, today: today)
        case .focus:      return classifyFocus(item, now: now, today: today)
        case .habit:      return classifyHabit(item, now: now, today: today)
        case .todo:       return classifyTodo(item, now: now, today: today)
        }
    }

    private static func classifyNTD(_ item: Item, now: Date, today: Date) -> (StatusBucket, Date)? {
        let isRoutine = item.recurrenceRule != nil
        if isRoutine {
            // 반복 NTD: today RC 기반으로 past 판정. RC date == today에 done/failed면 past.
            // 다른 날 RC(과거 occurrence 결과)는 영향 X — routineRecord(on: today)는 today 기준 lookup.
            if let rec = item.routineRecord(on: today) {
                if rec.failed { return (.past, rec.completedAt ?? now) }
                if rec.done { return (.past, rec.completedAt ?? now) }
            }
        } else {
            // 1회성 NTD: Item.status 기반. completedAt이 오늘일 때만 past 노출, 다른 날 종료된 건 위젯 범위 밖.
            // (이전: ntdRelevantOccurrenceDate가 과거 startDate를 반환 + ntdState=.ended로 past 분류되어
            //  과거에 포기/완료된 1회성 NTD가 위젯에 잔존하는 버그.)
            if item.itemStatus == .failed || item.itemStatus == .done {
                if let completed = item.completedAt,
                   Calendar.gmt.isDate(completed.calendarDateAnchor, inSameDayAs: today) {
                    return (.past, completed)
                }
                return nil
            }
        }

        // 진행중/예정 — ntdState 기반.
        guard let occ = item.ntdRelevantOccurrenceDate(at: now) else { return nil }
        let occDay = Calendar.gmt.startOfDay(for: occ)
        // 오늘보다 미래 occurrence는 노출 안 함 — "오늘" 범위.
        if occDay > today { return nil }
        guard let state = item.ntdState(on: occ, now: now),
              let start = item.ntdStartInstant(on: occ) else { return nil }
        switch state {
        case .scheduled:
            return (.scheduled, start)
        case .inProgress:
            return (.ongoing, item.ntdEndInstant(on: occ) ?? start.addingTimeInterval(24 * 3600))
        case .ended:
            // 반복 NTD가 ended state인데 RC 없음 = 위젯 노출 가치 낮음 (자동 완성 트리거 대기 등 비정상 상태).
            // 1회성은 위쪽 status 가드에서 이미 처리됐으므로 여기 도달 X.
            return nil
        }
    }

    private static func classifyActivity(_ item: Item, now: Date, today: Date) -> (StatusBucket, Date)? {
        guard isActiveToday(item, today: today) else {
            // 오늘 occurrence 아닌데 status=done이면 past로 노출 X — 오늘 일정 범위로 한정.
            return nil
        }
        let rec = item.routineRecord(on: today)
        if rec?.done == true {
            return (.past, rec?.completedAt ?? now)
        }
        // 진행중 — 종일 (start/end 없음). anchor는 오늘 자정으로 (같은 bucket 안에서 startDate 빠른 항목 먼저).
        return (.ongoing, today.addingTimeInterval(24 * 3600))
    }

    private static func classifyFocus(_ item: Item, now: Date, today: Date) -> (StatusBucket, Date)? {
        guard isActiveToday(item, today: today) else { return nil }
        let rec = item.routineRecord(on: today)
        if rec?.done == true {
            return (.past, rec?.completedAt ?? now)
        }
        return (.ongoing, today.addingTimeInterval(24 * 3600))
    }

    private static func classifyHabit(_ item: Item, now: Date, today: Date) -> (StatusBucket, Date)? {
        guard isActiveToday(item, today: today) else { return nil }
        let rec = item.routineRecord(on: today)
        if rec?.done == true {
            return (.past, rec?.completedAt ?? now)
        }
        return (.ongoing, today.addingTimeInterval(24 * 3600))
    }

    private static func classifyTodo(_ item: Item, now: Date, today: Date) -> (StatusBucket, Date)? {
        if let rule = item.recurrenceRule {
            // 반복 Todo — 오늘 occurrence가 있어야 노출.
            guard rule.occurs(on: today, startDate: item.startDate, endDate: item.recurrenceEndDate)
            else { return nil }
            if let rec = item.routineRecord(on: today), rec.done {
                return (.past, rec.completedAt ?? now)
            }
            guard let start = Item.localInstant(fromCalendarDate: today, hour: item.startHourInt)
            else { return nil }
            let span = item.spanDays
            let endDay = Calendar.gmt.date(byAdding: .day, value: span, to: today) ?? today
            let end = Item.localInstant(fromCalendarDate: endDay, hour: item.dueHourInt)
            return classifyTodoTime(start: start, end: end, hasExplicitTime: item.hasExplicitTime, now: now)
        }
        // 1회성 Todo
        // status=.done(완료) 또는 .failed(사용자 취소 — CancelTodoSheet에서 Item.status=.failed 설정).
        // 오늘 종료된 것만 past로 노출, 다른 날 종료는 위젯 "오늘" 범위 밖.
        if item.itemStatus == .done || item.itemStatus == .failed {
            if let completed = item.completedAt,
               Calendar.gmt.isDate(completed.calendarDateAnchor, inSameDayAs: today) {
                return (.past, completed)
            }
            return nil
        }
        guard item.todoSection(on: today, now: now) != nil else { return nil }
        guard let start = item.effectiveStartInstant else { return nil }
        let end = item.effectiveDueInstant
        let startDay = Calendar.gmt.startOfDay(for: item.startDate ?? today)
        // 오늘 이후 시작은 노출 안 함.
        if startDay > today { return nil }
        return classifyTodoTime(start: start, end: end, hasExplicitTime: item.hasExplicitTime, now: now)
    }

    private static func classifyTodoTime(start: Date, end: Date?, hasExplicitTime: Bool, now: Date)
        -> (StatusBucket, Date)
    {
        if !hasExplicitTime {
            // 시간 미설정 — 항상 진행중. anchor는 종료 instant or start+24h.
            return (.ongoing, end ?? start.addingTimeInterval(24 * 3600))
        }
        if now < start { return (.scheduled, start) }
        // 단일 일정 (start == end) — 시각 지나도 ongoing 유지. 사용자가 체크해야 사라지는 정책 (오늘탭과 통일).
        // 기간 (end > start) — 종료 시각 지나면 past.
        if let end = end, end > start, now > end { return (.past, end) }
        return (.ongoing, end ?? start.addingTimeInterval(24 * 3600))
    }

    /// 활동/집중/습관 공통 — 오늘이 active occurrence인지 판정.
    private static func isActiveToday(_ item: Item, today: Date) -> Bool {
        if let rule = item.recurrenceRule {
            return rule.occurs(on: today, startDate: item.startDate, endDate: item.recurrenceEndDate)
        }
        guard let start = item.startDate else { return false }
        return Calendar.gmt.isDate(start, inSameDayAs: today)
    }

    // MARK: - Progress 계산

    /// 목표 type 진행률 0~1. 할일은 0 (사용 안 함).
    static func computeProgress(for item: Item, today: Date, now: Date, bucket: StatusBucket) -> Double {
        switch item.itemKind {
        case .notTodo:
            if bucket == .scheduled { return 0 }
            if bucket == .past { return 1 }
            guard let occ = item.ntdRelevantOccurrenceDate(at: now),
                  let start = item.ntdStartInstant(on: occ) else { return 0 }
            let elapsed = now.timeIntervalSince(start)
            if let end = item.ntdEndInstant(on: occ) {
                let total = max(end.timeIntervalSince(start), 1)
                return max(0, min(elapsed / total, 1))
            }
            // 한계 미설정 — 30일 cap (락 위젯과 동일 정책).
            return max(0, min(elapsed / (30 * 24 * 3600), 1))
        case .activity:
            let current = Double(item.activityCurrentValue(on: today))
            // effective target — RC.targetSnapshot 우선, fallback item.target.
            let target = item.effectiveTargetValue(on: today) ?? 0
            return target > 0 ? max(0, min(current / target, 1)) : 0
        case .focus:
            // focusCurrentMinutes(on:)은 Services/Item+FocusSession.swift에 있으나 widget target 멤버십 X.
            // 같은 로직 inline — RC.valueRecorded 직접 read.
            let current = item.routineRecord(on: today)?.valueRecorded?.doubleValue ?? 0
            let target = item.effectiveTargetValue(on: today) ?? 0
            return target > 0 ? max(0, min(current / target, 1)) : 0
        case .habit:
            return bucket == .past ? 1 : 0
        case .todo:
            return 0
        }
    }

    // MARK: - 아이콘/색 resolve

    /// 목표: GoalIcon.symbolName (item.iconName이 rawValue) / 할일: 카테고리 아이콘 / 없으면 fallback.
    private static func resolveIcon(for item: Item) -> String {
        if item.itemKind.isGoal {
            if let raw = item.iconName, let g = GoalIcon(rawValue: raw) {
                return g.symbolName
            }
            // 목표인데 iconName 없음 (legacy NTD) → kind별 기본.
            return item.itemKind.goalTypeSymbolName
        }
        // 할일: 카테고리 아이콘 → 미설정 시 circle.
        if let cat = item.category, let name = cat.iconName, !name.isEmpty {
            return name
        }
        return "circle"
    }

    /// 색 rawValue (CategoryColor: "red", "blue"...). 위젯에서 Color로 매핑.
    /// 목표=item.iconColorHex / 할일=category.colorHex.
    private static func resolveColorHex(for item: Item) -> String? {
        if item.itemKind.isGoal { return item.iconColorHex }
        return item.category?.colorHex
    }

    // MARK: - Counts

    static func computeCounts(items: [Item], now: Date) -> ItemCounts {
        let today: Date = .todayCalendarAnchor
        var goalActive = 0, goalTotal = 0, todoActive = 0, todoTotal = 0
        for item in items {
            guard let cls = classify(item: item, now: now, today: today) else { continue }
            let isGoal = item.itemKind != .todo
            let isActiveBucket = cls.bucket != .past
            if isGoal {
                goalTotal += 1
                if isActiveBucket { goalActive += 1 }
            } else {
                todoTotal += 1
                if isActiveBucket { todoActive += 1 }
            }
        }
        return ItemCounts(goalActive: goalActive, goalTotal: goalTotal,
                          todoActive: todoActive, todoTotal: todoTotal)
    }

    // MARK: - Transition instant 수집 (timeline tier용)

    private static func transitionInstants(items: [Item], after now: Date) -> [Date] {
        let today: Date = .todayCalendarAnchor
        var set = Set<TimeInterval>()
        for item in items {
            for instant in instantsForTransition(item: item, now: now, today: today) {
                if instant > now { set.insert(instant.timeIntervalSince1970) }
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
                guard rule.occurs(on: today, startDate: item.startDate, endDate: item.recurrenceEndDate)
                else { return [] }
                let start = Item.localInstant(fromCalendarDate: today, hour: item.startHourInt)
                let span = item.spanDays
                let endDay = Calendar.gmt.date(byAdding: .day, value: span, to: today) ?? today
                let end = Item.localInstant(fromCalendarDate: endDay, hour: item.dueHourInt)
                return [start, end].compactMap { $0 }
            }
            return [item.effectiveStartInstant, item.effectiveDueInstant].compactMap { $0 }
        case .activity, .focus, .habit:
            // 종일 의미 — transition 없음. progress는 사용자 액션/HK sync로 변하며 reload는 별도 trigger.
            return []
        }
    }
}

// MARK: - Color resolve helper (View에서 사용)

extension ItemSnapshot {
    /// 위젯에서 표시할 색. iconColorHex가 CategoryColor rawValue면 그 색, 없으면 app tint.
    func resolvedColor() -> Color {
        if let raw = iconColorHex, let cc = CategoryColor(rawValue: raw) {
            return cc.color
        }
        return TintPreset.currentColor
    }
}

// MARK: - Views

struct MyDaysWidgetEntryView: View {

    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: MyDaysHomeEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                mediumLayout
            default:
                smallLayout
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: - 공간 추정 / fit
    //
    // ViewThatFits는 widget process 메모리 부담 + variant pass 비용 — deterministic 추정으로 처리.
    // - 위젯 content 영역 ~142pt (small/medium 동일 높이).
    // - 헤더 영역(date + counts) ~50pt.
    // - row 1줄(progress capsule or text + icon) ~22pt, row 간 spacing 4pt.
    //   item 1개당 effective ~26pt. budget 92pt면 약 3~4개.

    private static let widgetContentHeight: CGFloat = 142
    private static let headerHeight: CGFloat = 44  // 일자 큰 글자 + 우측 2줄(요일/카운트) 기준.
    private static let rowHeight: CGFloat = 28
    private static let rowSpacing: CGFloat = 5

    private static func fitCount(in budget: CGFloat) -> Int {
        guard budget > 0 else { return 0 }
        // 첫 row는 spacing 없음 → effective = rowHeight, 그 다음부터 spacing 포함.
        let extra = max(0, budget - rowHeight)
        return 1 + Int(extra / (rowHeight + rowSpacing))
    }

    private static func smallFitCount() -> Int {
        fitCount(in: widgetContentHeight - headerHeight)
    }

    private static func mediumLeftFitCount() -> Int {
        fitCount(in: widgetContentHeight - headerHeight)
    }

    private static func mediumRightFitCount() -> Int {
        fitCount(in: widgetContentHeight)
    }

    // MARK: - Header (날짜 + 카운트 박스)

    /// 좌측: 큰 일자 / 우측 stack: 요일(상, 좌측 정렬) + 카운트(하, 우측 정렬).
    /// small widget에서 한 줄에 모두 넣으면 카운트 숫자 잘림 → 우측 영역을 2줄로 분리해 공간 확보.
    private var headerRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(verbatim: Self.formatDay(entry.date))
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            VStack(spacing: 3) {
                Text(verbatim: Self.formatWeekday(entry.date))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                countsBox
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 우상단 1줄 카운트 박스. (scope) n/m  (checkmark.circle) n/m.
    private var countsBox: some View {
        HStack(spacing: 6) {
            countItem(symbol: "scope",
                      active: entry.counts.goalActive,
                      total: entry.counts.goalTotal)
            countItem(symbol: "checkmark.circle",
                      active: entry.counts.todoActive,
                      total: entry.counts.todoTotal)
        }
        .lineLimit(1)
    }

    private func countItem(symbol: String, active: Int, total: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: "\(active)/\(total)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Date formatters

    private static func formatDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "d"
        return f.string(from: date)
    }

    private static func formatWeekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f.string(from: date)
    }

    // MARK: - Row (목표 = progress capsule + 타이틀, 할일 = 아이콘 + 타이틀)

    @ViewBuilder
    private func itemRow(_ snap: ItemSnapshot) -> some View {
        HStack(spacing: 7) {
            Image(systemName: snap.iconName)
                .font(.subheadline)
                .foregroundStyle(snap.resolvedColor())
                .frame(width: 18, alignment: .center)
            if snap.isGoal {
                progressCapsule(snap)
            } else {
                Text(verbatim: snap.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // row는 고정 크기. 항목 갯수가 fit max보다 적으면 아래는 자연 빈 공간으로 둠.
        .frame(height: Self.rowHeight)
        // past bucket은 dim — 완료/포기/만료 시각화.
        .opacity(snap.bucket == .past ? 0.55 : 1.0)
    }

    /// 목표 row의 progress capsule + 타이틀 overlay.
    /// 배경 capsule + 진행률 fill capsule + 타이틀 (leading, 좌측 padding).
    @ViewBuilder
    private func progressCapsule(_ snap: ItemSnapshot) -> some View {
        let progress = max(0, min(snap.progress, 1))
        let fill = snap.resolvedColor()
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                Capsule()
                    .fill(fill.opacity(0.35))
                    .frame(width: max(0, proxy.size.width * progress))
                Text(verbatim: snap.title)
                    .font(.caption.weight(.semibold))
                    // NTDRow와 동일 패턴 — 라이트: goalColor(fill 위 또렷), 다크: .primary(white).
                    .foregroundStyle(colorScheme == .dark ? Color.primary : fill)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Layout 전략
    //
    // - row 박스 높이를 fit count × rowHeight + (fitCount-1) × rowSpacing 로 미리 계산.
    // - 이 박스를 widget 바닥에 정렬 → device별 widget 높이 차이는 박스 위쪽 여백이 흡수.
    // - 박스 안 row는 위부터 채움 (top 정렬). 항목 < fitCount면 박스 아래는 빈 공간이지만
    //   박스 자체가 바닥에 붙어 있어 widget 아래 여백 0.

    private static func boxHeight(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * rowSpacing
    }

    /// 박스 안 row 위 정렬 layout. 항목이 박스 fit보다 적으면 박스 아래는 빈 공간.
    @ViewBuilder
    private func rowBox(snaps: [ItemSnapshot], height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(snaps) { snap in
                itemRow(snap)
            }
            Spacer(minLength: 0)  // 박스 안 빈 자리를 아래로 밀어 row를 위 정렬.
        }
        .frame(height: height, alignment: .topLeading)
    }

    // MARK: - Small

    private var smallLayout: some View {
        let count = Self.smallFitCount()
        let snaps = Array(entry.snapshots.prefix(count))
        let box = Self.boxHeight(for: count)
        return VStack(spacing: 0) {
            headerRow
            Spacer(minLength: 0)  // 헤더와 박스 사이 flex — device별 widget 높이 차이 흡수.
            if snaps.isEmpty {
                emptyContent
            } else {
                rowBox(snaps: snaps, height: box)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Medium

    private var mediumLayout: some View {
        let leftMax = Self.mediumLeftFitCount()
        let rightMax = Self.mediumRightFitCount()
        let snaps = entry.snapshots
        let leftCount = min(snaps.count, leftMax)
        let leftSlice = Array(snaps.prefix(leftCount))
        let rest = Array(snaps.dropFirst(leftCount))
        let rightSlice = Array(rest.prefix(rightMax))
        let leftBox = Self.boxHeight(for: leftMax)
        let rightBox = Self.boxHeight(for: rightMax)
        // 빈 상태 — 양쪽 모두 비어있으면 headerRow만 두고 본문 가운데에 emptyContent.
        if snaps.isEmpty {
            return AnyView(
                VStack(spacing: 0) {
                    headerRow
                    Spacer(minLength: 0)
                    emptyContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            )
        }
        return AnyView(HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                headerRow
                Spacer(minLength: 0)
                rowBox(snaps: leftSlice, height: leftBox)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                rowBox(snaps: rightSlice, height: rightBox)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }

    /// 빈 상태 — 작은 아이콘 + "Nothing Today" / "오늘 일정 없음". 본문 영역 가운데 정렬.
    /// headerRow는 호출 측에서 함께 노출 (헤더 자체는 빈 상태에서도 보임).
    @ViewBuilder
    private var emptyContent: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("widget.empty.today")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 8)
    }
}

// MARK: - Widget Configuration

struct MyDaysWidget: Widget {
    let kind: String = "MyDaysWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MyDaysHomeProvider()) { entry in
            MyDaysWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(Text("widget.ntd.display_name"))
        .description(Text("widget.ntd.description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Preview

private let previewCounts = ItemCounts(goalActive: 2, goalTotal: 4, todoActive: 3, todoTotal: 5)

private let previewSnapshots: [ItemSnapshot] = [
    ItemSnapshot(
        id: "p1", kind: .notTodo, title: "16시간 단식",
        bucket: .ongoing, progress: 0.62,
        sortAnchor: .now.addingTimeInterval(3600),
        iconName: "fork.knife", iconColorHex: "blue"
    ),
    ItemSnapshot(
        id: "p2", kind: .activity, title: "걷기 10000보",
        bucket: .ongoing, progress: 0.3,
        sortAnchor: .now.addingTimeInterval(7200),
        iconName: "figure.walk", iconColorHex: "green"
    ),
    ItemSnapshot(
        id: "p3", kind: .focus, title: "공부 2시간",
        bucket: .scheduled, progress: 0,
        sortAnchor: .now.addingTimeInterval(10800),
        iconName: "hourglass.bottomhalf.filled", iconColorHex: "purple"
    ),
    ItemSnapshot(
        id: "p4", kind: .habit, title: "비타민",
        bucket: .ongoing, progress: 0,
        sortAnchor: .now.addingTimeInterval(14400),
        iconName: "pill.fill", iconColorHex: "orange"
    ),
    ItemSnapshot(
        id: "p5", kind: .todo, title: "보일러 점검",
        bucket: .ongoing, progress: 0,
        sortAnchor: .now.addingTimeInterval(7200),
        iconName: "wrench.adjustable.fill", iconColorHex: "red"
    ),
    ItemSnapshot(
        id: "p6", kind: .todo, title: "리포트 마감",
        bucket: .past, progress: 0,
        sortAnchor: .now.addingTimeInterval(-1800),
        iconName: "doc.text.fill", iconColorHex: nil
    )
]

#Preview(as: .systemSmall) {
    MyDaysWidget()
} timeline: {
    MyDaysHomeEntry(date: .now, snapshots: previewSnapshots, counts: previewCounts)
}

#Preview(as: .systemMedium) {
    MyDaysWidget()
} timeline: {
    MyDaysHomeEntry(date: .now, snapshots: previewSnapshots, counts: previewCounts)
}
