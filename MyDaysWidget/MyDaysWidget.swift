import CoreData
import SwiftUI
import UIKit
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
    /// 할일 2번째 라인 시간 라벨 (예: "12:00 - 13:00" / "9:00 시작"). 없으면 제목만. 목표는 nil.
    /// var + 기본값 — 기존 ItemSnapshot 생성부(프리뷰 등) 호환.
    var timeLabel: String? = nil

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
            // 할일 전용 위젯 — 목표(4-type)는 별도 GoalGridWidget에서 표시하므로 제외.
            guard item.itemKind == .todo else { continue }
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
            iconColorHex: resolveColorHex(for: item),
            timeLabel: todoTimeLabel(for: item, today: today)
        )
    }

    /// 할일 2번째 라인 시간 라벨. 목표/시간미지정/기간 중간일은 nil(제목만).
    /// - 단일일(시작==종료일) + 시간지정: "시작 - 종료" (시각 같으면 단일 시각).
    /// - 기간(시작≠종료일): 오늘이 시작일이면 "시작시각 시작", 종료일이면 "종료시각 종료", 그 외 nil.
    private static func todoTimeLabel(for item: Item, today: Date) -> String? {
        guard item.itemKind == .todo, item.hasExplicitTime else { return nil }
        guard let startDay = item.startDate else { return nil }
        let dueDay = item.dueDate ?? startDay
        let cal = Calendar.gmt
        if cal.isDate(startDay, inSameDayAs: dueDay) {
            // 단일일 + 시간 지정.
            if item.startHourInt == item.dueHourInt || item.dueHourInt >= 24 {
                return hourLabel(item.startHourInt)
            }
            return "\(hourLabel(item.startHourInt)) - \(hourLabel(item.dueHourInt))"
        }
        // 기간 — 오늘이 시작/종료일일 때만.
        if cal.isDate(today, inSameDayAs: startDay) {
            return String(format: NSLocalizedString("widget.todo.start_at", comment: ""), hourLabel(item.startHourInt))
        }
        if cal.isDate(today, inSameDayAs: dueDay) {
            return String(format: NSLocalizedString("widget.todo.end_at", comment: ""), hourLabel(item.dueHourInt))
        }
        return nil
    }

    /// 정수 hour(0~24) → 로케일 시각 문자열 ("14:00" / "오후 2:00"). 24+는 0시로 wrap.
    private static func hourLabel(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        var comps = DateComponents()
        comps.hour = h
        let date = Calendar.current.date(from: comps) ?? Date()
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jm")
        return f.string(from: date)
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

extension Color {
    /// HSB brightness 조정 (음수=어둡게, 양수=밝게). 라이트모드 텍스트 진하게용.
    func adjustBrightness(_ delta: CGFloat) -> Color {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return Color(hue: Double(h),
                     saturation: Double(s),
                     brightness: Double(max(0, min(1, b + delta))),
                     opacity: Double(a))
    }

    /// 다크모드 텍스트용 — 채도를 낮춰 파스텔화 + 명도 확보. 어두운 바탕에서 밝게 보임.
    /// (단순 brightness +는 이미 밝은 색에서 clamp돼 효과 없음 → 채도 down이 핵심.)
    func pastelBright(saturationScale: CGFloat, minBrightness: CGFloat) -> Color {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return Color(hue: Double(h),
                     saturation: Double(s * saturationScale),
                     brightness: Double(max(b, minBrightness)),
                     opacity: Double(a))
    }
}

// MARK: - 재사용 컴포넌트 (할일 컬럼) — 단독 위젯 + 조합 위젯 공용

/// 할일 행 레이아웃 상수/계산.
enum TodoLayout {
    static let widgetContentHeight: CGFloat = 142   // small/medium content 높이
    static let largeContentHeight: CGFloat = 320    // large content 높이(근사)
    static let headerHeight: CGFloat = 44
    static let rowHeightDouble: CGFloat = 36        // 시간 라벨 있는 2줄
    static let rowHeightSingle: CGFloat = 24        // 제목만 1줄
    static let rowSpacing: CGFloat = 4

    static func rowHeight(for snap: ItemSnapshot) -> CGFloat {
        snap.timeLabel == nil ? rowHeightSingle : rowHeightDouble
    }

    /// 높이 budget에 들어가는 만큼만 순서대로 (가변 높이 greedy).
    static func fitted(_ snaps: [ItemSnapshot], budget: CGFloat) -> [ItemSnapshot] {
        guard budget > 0 else { return [] }
        var result: [ItemSnapshot] = []
        var used: CGFloat = 0
        for snap in snaps {
            let h = rowHeight(for: snap)
            let add = result.isEmpty ? h : (rowSpacing + h)
            guard used + add <= budget else { break }
            used += add
            result.append(snap)
        }
        return result
    }
}

/// 할일 헤더 — 큰 일자 + 요일 + "할일 : n/m".
struct TodoHeader: View {
    let date: Date
    let counts: ItemCounts

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(verbatim: Self.formatDay(date))
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: Self.formatWeekday(date))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: String(format: NSLocalizedString("widget.todo.count_format", comment: ""),
                                      counts.todoActive, counts.todoTotal))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func formatDay(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "d"; return f.string(from: d)
    }
    private static func formatWeekday(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("EEEE"); return f.string(from: d)
    }
}

/// 할일 행 — round box + 세로 색상바 + 제목 + 시간 라벨 (아이콘 없음).
struct TodoRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    let snap: ItemSnapshot

    var body: some View {
        let color = snap.resolvedColor()
        let isDark = colorScheme == .dark
        let titleColor: Color = isDark ? Color(white: 0.82) : color.adjustBrightness(-0.34)
        let timeColor = isDark ? color.pastelBright(saturationScale: 0.65, minBrightness: 0.88) : color
        let bgOpacity: Double = isDark ? 0.24 : 0.11
        HStack(spacing: 0) {
            Rectangle()
                .fill(color)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: snap.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let t = snap.timeLabel {
                    Text(verbatim: t)
                        .font(.caption2)
                        .foregroundStyle(timeColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: TodoLayout.rowHeight(for: snap))
        .background(color.opacity(bgOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 할일 빈 상태.
struct TodoEmptyView: View {
    var body: some View {
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

/// 할일 컬럼 — (옵션 헤더) + 행들 위부터. rows는 호출 측에서 미리 fit.
/// showEmptyState=true면 rows 비었을 때 빈 안내, false면 빈 자리(오버플로우 컬럼용).
struct TodoColumn: View {
    let rows: [ItemSnapshot]
    var date: Date = Date()
    var counts: ItemCounts = .empty
    var showHeader: Bool = true
    var showEmptyState: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: TodoLayout.rowSpacing) {
            if showHeader {
                TodoHeader(date: date, counts: counts)
            }
            if rows.isEmpty {
                if showEmptyState { TodoEmptyView() }
            } else {
                ForEach(rows) { TodoRowView(snap: $0) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Views

struct MyDaysWidgetEntryView: View {

    @Environment(\.widgetFamily) private var family
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

    // 헤더 아래로 항목을 위부터 자연 스택. fitted로 widget 높이에 맞춰 개수 제한.

    private var smallLayout: some View {
        let rows = TodoLayout.fitted(entry.snapshots,
                                     budget: TodoLayout.widgetContentHeight - TodoLayout.headerHeight)
        return TodoColumn(rows: rows, date: entry.date, counts: entry.counts)
    }

    private var mediumLayout: some View {
        let all = entry.snapshots
        if all.isEmpty {
            return AnyView(TodoColumn(rows: [], date: entry.date, counts: entry.counts))
        }
        let left = TodoLayout.fitted(all, budget: TodoLayout.widgetContentHeight - TodoLayout.headerHeight)
        let rest = Array(all.dropFirst(left.count))
        let right = TodoLayout.fitted(rest, budget: TodoLayout.widgetContentHeight)
        return AnyView(HStack(alignment: .top, spacing: 12) {
            TodoColumn(rows: left, date: entry.date, counts: entry.counts, showHeader: true)
            // 오른쪽은 오버플로우 — 비면 빈 자리.
            TodoColumn(rows: right, showHeader: false, showEmptyState: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
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
