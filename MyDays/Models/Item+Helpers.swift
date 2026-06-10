import CoreData
import Foundation

// MARK: - Item helpers
//
// 본 파일의 모든 calendar date 비교/계산은 `Calendar.gmt` (UTC 고정)을 사용한다.
// startDate / dueDate / RoutineCompletion.date는 UTC 자정 anchor로 저장되므로,
// `Calendar.current`로 다루면 디바이스 timezone에 따라 라벨이 흔들린다 (예: KST→PDT 이동 시 하루 어긋남).
// Date.todayCalendarAnchor / Date.calendarDateAnchor 참고: Models/CalendarDate.swift

/// 항목의 기간 안에서 특정 calendar date가 차지하는 위치 — 반복 occurrence 라벨 결정용.
enum OccurrencePosition {
    case start, middle, end
}

/// 1회성 Todo 섹션 분류 (TodayView 시작/진행 중/마감 섹션).
/// 통합 모델: 모든 항목은 (effectiveStartInstant, effectiveDueDate) 쌍으로 표현.
enum TodoTodaySection { case start, inProgress, due }

extension Item {

    var itemKind: ItemKind {
        get { ItemKind(rawValue: kind) ?? .todo }
        set { kind = newValue.rawValue }
    }

    var itemPriority: Priority {
        get { Priority(rawValue: priority) ?? .medium }
        set { priority = newValue.rawValue }
    }

    var itemStatus: Status {
        get { Status(rawValue: status) ?? .pending }
        set { status = newValue.rawValue }
    }

    var itemStartTimeOfDay: TimeOfDay {
        get { TimeOfDay(rawValue: startTimeOfDay) ?? .none }
        set { startTimeOfDay = newValue.rawValue }
    }

    var itemDueTimeOfDay: TimeOfDay {
        get { TimeOfDay(rawValue: dueTimeOfDay) ?? .none }
        set { dueTimeOfDay = newValue.rawValue }
    }

    // MARK: - 시각 (Todo·NTD 공통)
    //
    // startHour / dueHour / ntdDurationHour는 Core Data에 NSNumber? 형태로 저장됨
    // (nil과 0을 구분하기 위해 scalar 대신 NSNumber 사용).
    // Swift에선 Int? 접근이 자연스러우니 래퍼를 둔다.

    // 단순화 모델: hour는 항상 값 보유. 시간 미설정 = startHour=0, dueHour=24 sentinel.
    // CD 스키마(Int16?)는 그대로 두되, accessor를 non-optional로 노출해 nil 체크 제거.
    // 기존 nil 데이터는 0/24 default로 lenient 해석.

    /// 시작 시각 — 항상 0~23 범위 (0 = 자정 = "시간 미설정" 의미).
    var startHourInt: Int {
        get { startHour?.intValue ?? 0 }
        set { startHour = NSNumber(value: newValue) }
    }

    /// 종료 시각 — 항상 0~24 범위. 24는 "시간 미설정" sentinel (다음 날 0시로 해석).
    /// hasTime 판정: `dueHourInt < 24` → true (시간 명시), `== 24` → false (종일).
    var dueHourInt: Int {
        get { dueHour?.intValue ?? 24 }
        set { dueHour = NSNumber(value: newValue) }
    }

    /// 시간 명시 여부 — startHour 또는 dueHour 중 하나라도 명시 설정됐으면 true.
    /// 정책: startHour=0 + dueHour=24 = 시간 미설정 default (종일).
    /// - startHour > 0: 사용자가 시작 시각 명시 설정 (예: 활동 "9시부터 카운트")
    /// - dueHour < 24: 사용자가 종료 시각 명시 설정 (예: Todo "17시까지")
    /// 둘 다 있으면 기간 범위.
    var hasExplicitTime: Bool { startHourInt > 0 || dueHourInt < 24 }

    var ntdDurationHourInt: Int? {
        get { ntdDurationHour?.intValue }
        set { ntdDurationHour = newValue.map(NSNumber.init(value:)) }
    }

    // MARK: - 활동 목표 필드 accessor
    //
    // activityTargetValue / activitySourceType는 NSNumber? 형태 (nil 구분 필요).
    // activityUnit은 String? 그대로.

    /// 활동 목표 수치 — 예: 100(회), 2.0(L), 10000(보). nil이면 미설정.
    var activityTargetValueDouble: Double? {
        get { activityTargetValue?.doubleValue }
        set { activityTargetValue = newValue.map(NSNumber.init(value:)) }
    }

    /// 활동 측정 source. nil 또는 manual default.
    var activitySource: ActivitySourceType {
        get { ActivitySourceType(rawValue: activitySourceType?.int16Value ?? 0) ?? .manual }
        set { activitySourceType = NSNumber(value: newValue.rawValue) }
    }

    /// 활동 목표 수치 — Phase B는 정수만 입력. UI 바인딩 편의용 Int accessor.
    var activityTargetValueInt: Int? {
        get { activityTargetValueDouble.map { Int($0) } }
        set { activityTargetValueDouble = newValue.map { Double($0) } }
    }

    /// 활동 target 기반 quick step 계산 — 사용자가 ~20회 누르면 완료되는 정도의 "nice" 단위.
    /// 후보 nice step: 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000.
    /// 예: target=100 → step=5, target=20000 → step=1000.
    private static let activityNiceSteps: [Int] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000]

    static func activityQuickStep(target: Int) -> Int {
        let goal = max(target / 20, 1)
        return activityNiceSteps.first(where: { $0 >= goal }) ?? 10000
    }

    /// 새 NTD 생성 시 default 시작 시각: 현재 시각의 다음 정각(0~23).
    /// 예) now=14:23 → 15. now=14:00 → 14. now=23:30 → 0 (다음 날 0시).
    /// 호출 측에서 23→0 wrap 시 startDate를 익일로 보정해야 할 수도 있음 (현재는 단순 wrap).
    static var defaultNextTopOfHour: Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let h = comps.hour ?? 0
        let m = comps.minute ?? 0
        return m == 0 ? h : (h + 1) % 24
    }

    /// NTD default 시작 시각 — 오전 6시. 사용자 결정값 (16시간 단식 → 22시 종료 패턴).
    static let defaultNTDStartHour: Int = 6

    /// NTD default 목표 유지 시간 — 16시간 (대중적 단식). 목표 24시간 cap 안.
    static let defaultNTDDurationHour: Int = 16

    /// 주어진 calendar date(UTC anchor)에서 이 NTD의 실제 시작 instant 계산.
    /// 의미: "그 날짜의 사용자 local hour:00" (wall-clock semantics).
    /// 여행 시 같은 ritual이 현지 시각으로 작동.
    func ntdStartInstant(on calendarDate: Date) -> Date? {
        return Self.localInstant(fromCalendarDate: calendarDate, hour: startHourInt)
    }

    /// calendar date(UTC anchor) + wall-clock hour → local instant.
    /// 알림·NTD 시각 계산 공통 helper.
    /// hour 24는 sentinel — "다음 날 0시"로 해석 (시간 없는 항목의 종료 시각 모델).
    static func localInstant(fromCalendarDate calendarDate: Date, hour: Int) -> Date? {
        if hour == 24 {
            guard let nextDay = Calendar.gmt.date(byAdding: .day, value: 1, to: calendarDate) else { return nil }
            return localInstant(fromCalendarDate: nextDay, hour: 0)
        }
        let dateParts = Calendar.gmt.dateComponents([.year, .month, .day], from: calendarDate)
        var localParts = DateComponents()
        localParts.year = dateParts.year
        localParts.month = dateParts.month
        localParts.day = dateParts.day
        localParts.hour = hour
        localParts.minute = 0
        localParts.second = 0
        return Calendar.current.date(from: localParts)
    }

    // MARK: - Effective time values
    //
    // 통일 모델: 모든 dated 항목은 (startInstant, dueInstant) 쌍으로 표현.
    // hour accessor가 non-optional이라 별도 effective default 불필요 — 직접 사용.

    /// 종료일 — 미설정이면 시작일과 동일 (단일 일정 default).
    var effectiveDueDate: Date? {
        return dueDate ?? startDate
    }

    /// 시작 instant (local). startDate 있으면 항상 계산.
    var effectiveStartInstant: Date? {
        guard let s = startDate else { return nil }
        return Item.localInstant(fromCalendarDate: s, hour: startHourInt)
    }

    /// 종료 instant (local). effectiveDueDate 있으면 항상 계산. hour=24면 next day 0시.
    var effectiveDueInstant: Date? {
        guard let d = effectiveDueDate else { return nil }
        return Item.localInstant(fromCalendarDate: d, hour: dueHourInt)
    }

    /// 단일 일정 판정 — startDate==dueDate 같은 날 + (종료 시각 미설정 OR startHour==dueHour).
    /// 사용자 정의:
    ///   - 같은 날 + dueHour==24 (종료 시각 없음): 단일 (start time 유무 무관, 종일 의미)
    ///     · startHour=0/dueHour=24 → 시간 미설정 종일
    ///     · startHour=9/dueHour=24 → "9시 시작, 종일" (start-only)
    ///   - 같은 날 + startHour==dueHour: 단일 (단일 시각)
    ///   - 다른 날 또는 같은 날 + startH<dueH: 기간
    var isSingleSchedule: Bool {
        guard let s = startDate, let d = dueDate else { return true }
        if !Calendar.gmt.isDate(s, inSameDayAs: d) { return false }
        if dueHourInt >= 24 { return true }
        return startHourInt == dueHourInt
    }

    /// 카운트다운/색상 전환의 다음 변환 instant. TimelineView adaptive schedule 갱신 target.
    /// - NTD: ntdState 기준 — scheduled(시작 instant) / inProgress(종료 instant, nil 가능) / ended(nil)
    /// - Todo: 적용 occurrence start/due 중 아직 안 지난 가장 가까운 instant
    /// nil 반환 시 schedule은 default 60s 간격으로 fallback.
    func nextCountdownInstant(viewDate: Date, now: Date) -> Date? {
        if itemKind == .notTodo {
            guard let occ = ntdRelevantOccurrenceDate(at: now),
                  let state = ntdState(on: occ, now: now)
            else { return nil }
            switch state {
            case .scheduled:  return ntdStartInstant(on: occ)
            case .inProgress: return ntdEndInstant(on: occ)  // 목표 미설정이면 nil
            case .ended:      return nil
            }
        }
        guard let occStart = referenceOccurrenceStartDate(viewDate: viewDate) else { return nil }
        let span = recurrenceRule != nil ? spanDays : 0
        let occDueDay: Date = (recurrenceRule != nil)
            ? (Calendar.gmt.date(byAdding: .day, value: span, to: occStart) ?? occStart)
            : (effectiveDueDate ?? occStart)
        let startInst = Item.localInstant(fromCalendarDate: occStart, hour: startHourInt)
        let dueInst = Item.localInstant(fromCalendarDate: occDueDay, hour: dueHourInt)
        if let s = startInst, now < s { return s }
        // 단일 시각 (s==d): 시작 후 → 다음 transition은 자정 (occurrence day 끝).
        if let s = startInst, let d = dueInst, s == d {
            guard let nextDay = Calendar.gmt.date(byAdding: .day, value: 1, to: occDueDay),
                  let endOfDay = Item.localInstant(fromCalendarDate: nextDay, hour: 0)
            else { return nil }
            return now < endOfDay ? endOfDay : nil
        }
        if let d = dueInst, now < d { return d }
        return nil
    }

    /// 진행 중 판정 — 적용 occurrence 시작 instant 후 + 종료 instant 전.
    /// 라벨/체크박스 색상(푸른 라인) 등 시각 피드백 공통 helper.
    /// - 단일 시각 미설정 (s==자정, d==다음날 자정): 0~24시 종일 진행 중
    /// - **단일 시각 있음 (s==d, 같은 instant)**: 시작 후 occurrence day 자정까지 진행 중 — todoSection의 단일 의미와 일관 ("시작 후 영속")
    /// - 기간/다일 occurrence: [start, due) 범위 안이면 진행 중
    /// `occurrenceStartOverride` — multi-occurrence 그룹 내 특정 occurrence를 명시할 때 사용. nil이면 viewDate로 자동 계산.
    func isInProgress(viewDate: Date, now: Date, occurrenceStartOverride: Date? = nil) -> Bool {
        guard let occStart = occurrenceStartOverride ?? referenceOccurrenceStartDate(viewDate: viewDate) else { return false }
        let span = recurrenceRule != nil ? spanDays : 0
        let occDueDay: Date = (recurrenceRule != nil)
            ? (Calendar.gmt.date(byAdding: .day, value: span, to: occStart) ?? occStart)
            : (effectiveDueDate ?? occStart)
        let startInst = Item.localInstant(fromCalendarDate: occStart, hour: startHourInt)
        let dueInst = Item.localInstant(fromCalendarDate: occDueDay, hour: dueHourInt)
        if let s = startInst, now < s { return false }
        // 단일 시각 (s==d): 단순 "now >= d → false" 적용 시 시작 직후 false 되는 edge case 회피.
        // occurrence day 자정(다음 날 0시)까지 inProgress 유지.
        if let s = startInst, let d = dueInst, s == d {
            guard let nextDay = Calendar.gmt.date(byAdding: .day, value: 1, to: occDueDay),
                  let endOfDay = Item.localInstant(fromCalendarDate: nextDay, hour: 0) else {
                return true
            }
            return now < endOfDay
        }
        if let d = dueInst, now >= d { return false }
        return true
    }

    /// `viewDate`가 어떤 occurrence(또는 다일 occurrence 범위) 안이면 그 occurrence start date 반환.
    /// 반복 항목에서 적용 라벨 계산 anchor로 사용.
    /// 단일 day occurrence는 viewDate가 rule.occurs면 viewDate 자신 반환.
    func occurrenceStartDate(on viewDate: Date) -> Date? {
        guard let rule = recurrenceRule, let anchor = startDate else { return nil }
        let span = spanDays
        let day = Calendar.gmt.startOfDay(for: viewDate)
        for offset in 0...span {
            guard let candidate = Calendar.gmt.date(byAdding: .day, value: -offset, to: day) else { continue }
            if rule.occurs(on: candidate, startDate: anchor, endDate: recurrenceEndDate) {
                return candidate
            }
        }
        return nil
    }

    /// 주어진 calendar date를 cover하는 모든 occurrence start dates (오래된 순).
    /// 반복 항목: offset 0...span 전체 검사 — multi-day 겹침 시 여러 start 반환 가능.
    /// 1회성: viewDate가 [startDate, dueDate] 안이면 startDate 1개, 아니면 empty.
    /// TodayView에서 같은 일자에 여러 occurrence가 겹칠 때 모두 표시하는 용도.
    func occurrenceStartsCovering(date viewDate: Date) -> [Date] {
        let day = Calendar.gmt.startOfDay(for: viewDate)
        if let rule = recurrenceRule, let anchor = startDate {
            let span = spanDays
            var starts: [Date] = []
            // offset이 큰 것(오래된 시작)부터 → 결과는 chronological order(오래된 → 최근).
            for offset in (0...span).reversed() {
                guard let candidate = Calendar.gmt.date(byAdding: .day, value: -offset, to: day) else { continue }
                if rule.occurs(on: candidate, startDate: anchor, endDate: recurrenceEndDate) {
                    starts.append(candidate)
                }
            }
            return starts
        }
        // 1회성
        guard let s = startDate else { return [] }
        let dueDay = effectiveDueDate ?? s
        let startDay = Calendar.gmt.startOfDay(for: s)
        let endDay = Calendar.gmt.startOfDay(for: dueDay)
        return (startDay <= day && day <= endDay) ? [s] : []
    }

    /// 라벨 계산용 적용 occurrence start.
    /// - 1회성: item.startDate
    /// - 반복: viewDate가 occurrence 범위면 그 start, 아니면 다음 future occurrence
    func referenceOccurrenceStartDate(viewDate: Date) -> Date? {
        if recurrenceRule == nil {
            return startDate
        }
        if let occ = occurrenceStartDate(on: viewDate) {
            return occ
        }
        guard let rule = recurrenceRule else { return nil }
        // cursor=viewDate — nextOccurrence는 referenceDate 포함 검사 (CLAUDE.md 명시).
        // 위에서 occurrenceStartDate가 nil 반환 = viewDate 자체는 occurrence 아님 →
        // nextOccurrence가 viewDate skip하고 다음 future occurrence 반환.
        // ⚠️ 이전엔 cursor = viewDate-1로 잘못 set돼서 과거 DTSTART(예: 5/30 토 anchor)가
        // 반환되는 버그가 있었음 (5/31 일요일 viewDate인데 cursor 5/30이 DTSTART 매치).
        return rule.nextOccurrence(after: viewDate, startDate: startDate, endDate: recurrenceEndDate)
    }

    /// 1회성 Todo 섹션 분류 (TodayView / ItemRow 공유 helper).
    /// - **단일**: 시작 instant 전 → 시작, 이후 → 진행 중 (마감 섹션 안 감)
    /// - **기간**: 시작 전 → 시작, 종료일 → 마감, 중간 → 진행, 종료일 이후 → nil
    ///   단 displayedDate가 오늘 + status==.pending이면 overdue로 .due 반환 (오늘 페이지에만 노출).
    func todoSection(on displayedDate: Date, now: Date) -> TodoTodaySection? {
        guard let startInst = effectiveStartInstant,
              let due = effectiveDueDate
        else { return nil }
        let dueDay = Calendar.gmt.startOfDay(for: due)
        let displayedDay = Calendar.gmt.startOfDay(for: displayedDate)

        if isSingleSchedule {
            // 단일: 마감 섹션 안 감. 시간 후엔 영속적 진행 중 (사용자 체크해야 사라짐).
            return now < startInst ? .start : .inProgress
        }
        // 기간 — 시간/날짜 기반 분기
        if now < startInst { return .start }
        if Calendar.gmt.isDate(displayedDay, inSameDayAs: dueDay) { return .due }
        if displayedDay < dueDay { return .inProgress }
        // displayedDay > dueDay — overdue 미체크는 오늘 페이지에서만 노출.
        let today = Calendar.gmt.startOfDay(for: .todayCalendarAnchor)
        if Calendar.gmt.isDate(displayedDay, inSameDayAs: today),
           itemStatus == .pending {
            return .due
        }
        return nil
    }

    /// 주어진 calendar date의 NTD 종료 instant. ntdDurationHour가 nil이면 nil (한계까지 = 종료 미정).
    func ntdEndInstant(on calendarDate: Date) -> Date? {
        guard let start = ntdStartInstant(on: calendarDate),
              let duration = ntdDurationHourInt else { return nil }
        return Calendar.current.date(byAdding: .hour, value: duration, to: start)
    }

    /// 주어진 calendar date의 occurrence가 `now` 기준 어느 상태인지.
    /// - .scheduled: 시작 전
    /// - .inProgress: 시작 ~ 종료 사이 (종료 미설정이면 시작 이후 계속 inProgress)
    /// - .ended: 종료 이후 (종료 미설정이면 도달 불가)
    enum NTDState {
        case scheduled
        case inProgress
        case ended
    }

    func ntdState(on calendarDate: Date, now: Date = Date()) -> NTDState? {
        guard let start = ntdStartInstant(on: calendarDate) else { return nil }
        if now < start { return .scheduled }
        guard let end = ntdEndInstant(on: calendarDate) else {
            // 종료 미설정 → 시작 이후 계속 inProgress.
            return .inProgress
        }
        if now < end { return .inProgress }
        return .ended
    }

    /// 이 NTD가 calendar date `d`에 occurrence를 갖는지.
    /// - 반복 NTD: RecurrenceRule.occurs(on:, endDate: recurrenceEndDate)
    /// - 1회성: startDate == d
    func ntdOccurs(on calendarDate: Date) -> Bool {
        if let rule = recurrenceRule {
            return rule.occurs(on: calendarDate, startDate: startDate, endDate: recurrenceEndDate)
        }
        guard let start = startDate else { return false }
        return Calendar.gmt.isDate(start, inSameDayAs: calendarDate)
    }

    /// 해당 calendar date에 RoutineCompletion 레코드가 있는지 (성공/포기 무관).
    /// 반복 NTD/Todo의 "이미 처리된 occurrence" 판별에 사용.
    func hasRoutineRecord(on date: Date) -> Bool {
        routineRecord(on: date) != nil
    }

    /// occurrence 기록 전체 (성공·포기 포함). completedAt 최신순(사용자 액션 시점).
    /// 편집 화면 "활동 기록" section 표시용. Todo routine + NTD(1회성·반복) + 활동 공통.
    /// 표시 조건: done OR failed OR (활동 progress: valueRecorded > 0).
    /// 빈 RoutineCompletion은 의미 없으므로 제외.
    /// completedAt이 nil인 legacy record는 record.date로 fallback 정렬.
    var routineHistoryRecords: [RoutineCompletion] {
        let comps = (completions as? Set<RoutineCompletion>) ?? []
        return comps
            .filter { rc in
                let value = rc.valueRecorded?.doubleValue ?? 0
                return rc.done || rc.failed || value > 0
            }
            .sorted {
                let l = $0.completedAt ?? $0.date ?? .distantPast
                let r = $1.completedAt ?? $1.date ?? .distantPast
                return l > r
            }
    }

    /// 해당 calendar date의 RoutineCompletion 레코드 반환 (없으면 nil).
    /// done/failed 구분 등 record 자체가 필요할 때 사용.
    func routineRecord(on date: Date) -> RoutineCompletion? {
        let day = Calendar.gmt.startOfDay(for: date)
        let completions = (self.completions as? Set<RoutineCompletion>) ?? []
        return completions.first { c in
            guard let d = c.date else { return false }
            return Calendar.gmt.isDate(d, inSameDayAs: day)
        }
    }

    /// 명시적 취소/포기 — NTD 포기(NTDRow.giveUp)와 Todo 취소가 공유하는 진입점.
    /// per-occurrence 개념 → 1회성·반복 모두 `RoutineCompletion(failed=true, comment)` 기록.
    /// 1회성은 추가로 `Item.status=.failed` + completedAt + 알림 취소.
    /// 활동 로그는 `.failed`로 통일 (NTD/Todo 의미 구분은 view layer 라벨에서).
    func cancel(occurrenceDate: Date, comment: String?, in context: NSManagedObjectContext) {
        let now = Date()
        let comp = RoutineCompletion(context: context)
        comp.id = UUID()
        comp.date = Calendar.gmt.startOfDay(for: occurrenceDate)
        comp.done = false
        comp.failed = true
        comp.comment = comment
        comp.completedAt = now
        comp.item = self
        updatedAt = now

        if recurrenceRule == nil {
            itemStatus = .failed
            completedAt = now
            cancelAllNotifications()
        }
        ItemEvent.log(.failed, on: self, in: context, note: comment)
        do {
            try context.save()
        } catch {
            assertionFailure("Item.cancel save failed: \(error)")
        }
    }

    /// 현재 진행 중이거나 가장 가까운 다음 NTD occurrence의 calendar date.
    /// ListView 등에서 "다음 일정까지 남은 시간" 같은 표시에 사용.
    /// 이미 처리된(성공/포기 record 존재) occurrence는 건너뜀.
    /// nil 반환: 1회성 NTD가 startDate 없거나 / 반복 NTD가 종료일까지 더 이상 occurrence 없을 때.
    func ntdRelevantOccurrenceDate(at now: Date = Date()) -> Date? {
        // 진행 중 occurrence 우선 (record 없는 것만).
        if let inProgress = ntdInProgressOccurrenceDate(at: now) {
            return inProgress
        }
        if let rule = recurrenceRule {
            // 반복 NTD: 오늘부터 시작해 record 없는 첫 occurrence 검색.
            // rule.nextOccurrence가 today를 반환할 수 있어 today를 시작점으로 잡되,
            // record 있으면 다음 날부터 다시 검색.
            var cursor: Date = .todayCalendarAnchor
            // 안전 한도 — 무한 루프 방지. 보통 한두 번 안에 결과 도출.
            for _ in 0..<400 {
                guard let next = rule.nextOccurrence(after: cursor, startDate: startDate, endDate: recurrenceEndDate) else {
                    return nil
                }
                if !hasRoutineRecord(on: next) {
                    return next
                }
                guard let bumped = Calendar.gmt.date(byAdding: .day, value: 1, to: next) else {
                    return nil
                }
                cursor = bumped
            }
            return nil
        }
        // 1회성: startDate.
        return startDate
    }

    /// ListView 등에서 "다음 NTD까지 남은 시간"을 짧게 표시하는 라벨.
    /// 예: "5시간 23분 남음" (진행 중, 목표 있음) / "1시간 42분 경과" (진행 중, 한계까지)
    ///    / "3시간 후" (시작 전) / nil (해당 없음)
    func ntdCountdownLabel(at now: Date = Date()) -> String? {
        guard let occurrenceDate = ntdRelevantOccurrenceDate(at: now),
              let state = ntdState(on: occurrenceDate, now: now)
        else { return nil }
        switch state {
        case .scheduled:
            guard let start = ntdStartInstant(on: occurrenceDate) else { return nil }
            let remaining = Int(start.timeIntervalSince(now))
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.countdown.in_future", comment: ""),
                Self.formatNTDDuration(seconds: remaining)
            )
        case .inProgress:
            if let end = ntdEndInstant(on: occurrenceDate) {
                let remaining = Int(end.timeIntervalSince(now))
                return String.localizedStringWithFormat(
                    NSLocalizedString("ntd.countdown.remaining", comment: ""),
                    Self.formatNTDDuration(seconds: max(0, remaining))
                )
            } else {
                guard let start = ntdStartInstant(on: occurrenceDate) else { return nil }
                let elapsed = Int(now.timeIntervalSince(start))
                return String.localizedStringWithFormat(
                    NSLocalizedString("ntd.countdown.elapsed", comment: ""),
                    Self.formatNTDDuration(seconds: max(0, elapsed))
                )
            }
        case .ended:
            // 자동 완성 직전 일시적 상태. ListView는 표시 안 함.
            return nil
        }
    }

    /// 초 → "5일 8시간" / "5시간" / "5시간 23분" / "23분" / "30초" 형식.
    /// 규칙:
    ///   - 24시간 이상: "%일 %시간" (시간 0이면 "%일")
    ///   - 8~23시간: 시간만 ("8시간"). 분 단위 정밀도 무시.
    ///   - 1~7시간: "5시간 23분" (분 0이면 "5시간")
    ///   - 1~59분: "23분"
    ///   - <1분: "30초"
    static func formatNTDDuration(seconds totalSec: Int) -> String {
        let s = max(0, totalSec)
        let days = s / 86400
        let hours = (s % 86400) / 3600
        let minutes = (s % 3600) / 60
        let secs = s % 60
        if days > 0 {
            if hours > 0 {
                return String.localizedStringWithFormat(
                    NSLocalizedString("ntd.countdown.d_h_format", comment: ""),
                    days, hours
                )
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.countdown.d_format", comment: ""),
                days
            )
        }
        if hours >= 8 {
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.countdown.h_format", comment: ""),
                hours
            )
        }
        if hours > 0 && minutes > 0 {
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.countdown.h_m_format", comment: ""),
                hours, minutes
            )
        }
        if hours > 0 {
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.countdown.h_format", comment: ""),
                hours
            )
        }
        if minutes > 0 {
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.countdown.m_format", comment: ""),
                minutes
            )
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("ntd.countdown.s_format", comment: ""),
            secs
        )
    }

    /// NTD occurrence가 calendar date 차원에서 차지하는 노출 범위 (둘 다 UTC anchor).
    ///
    /// TodayView에서 displayedDate가 어떤 occurrence의 진행 기간 안에 있는지 판정용.
    ///   - 시작 = occurrenceDate의 UTC 자정.
    ///   - 종료 = 종료 instant의 **local** calendar date를 UTC anchor로.
    ///
    /// 종료 instant 결정:
    ///   - 목표 시간(duration) 설정됨: 계획된 종료 instant
    ///     (실제 완료/포기와 무관 — 계획된 일자에 계속 노출 → 완료/포기 row로 표시)
    ///   - duration 없음 + RC 기록(완료/포기) 있음: RC.completedAt
    ///   - duration 없음 + 1회성 종료(Item.status done/failed): item.completedAt
    ///   - duration 없음 + **반복** + RC 없음: 다음 occurrence가 이미 시작됐다면 그 시점에 implicit end
    ///     (사용자가 명시 종료 안 해도 다음 occurrence가 자동 교체 — 안 그러면 lookback 모든 occurrence가 today를 cover)
    ///   - duration 없음 + 1회성/마지막 진행 중: now
    func ntdOccurrenceCalendarRange(occurrenceDate: Date, now: Date = Date()) -> (start: Date, end: Date) {
        let start = Calendar.gmt.startOfDay(for: occurrenceDate)
        let endInstant: Date
        if ntdDurationHourInt != nil {
            endInstant = ntdEndInstant(on: occurrenceDate) ?? now
        } else if let rc = routineRecord(on: occurrenceDate), let ce = rc.completedAt {
            endInstant = ce
        } else if recurrenceRule == nil,
                  (itemStatus == .done || itemStatus == .failed),
                  let ce = completedAt {
            endInstant = ce
        } else if let rule = recurrenceRule,
                  let nextOcc = rule.nextOccurrence(after: occurrenceDate, startDate: startDate, endDate: recurrenceEndDate),
                  let nextStart = ntdStartInstant(on: nextOcc),
                  nextStart <= now {
            endInstant = nextStart
        } else {
            endInstant = now
        }
        let end = endInstant.calendarDateAnchor
        return (start, end)
    }

    /// `displayedDate` 근처에서 visible할 가능성이 있는 NTD occurrence start dates.
    /// TodayView가 각 occurrence를 `ntdOccurrenceCalendarRange`로 검사할 후보 list.
    ///
    /// - 1회성: startDate 1개 (있으면)
    /// - 반복: lookback 범위 내 forward iterate.
    ///   - duration 설정: ceil(duration/24) + 1일 lookback (occurrence 끝이 displayedDate 안까지 닿을 수 있는 최대)
    ///   - duration 없음: 보수적으로 31일 lookback
    func ntdOccurrenceStartCandidates(coveringDate displayedDate: Date) -> [Date] {
        if recurrenceRule == nil {
            return startDate.map { [$0] } ?? []
        }
        guard let rule = recurrenceRule else { return [] }
        let lookbackDays: Int = {
            if let h = ntdDurationHourInt { return max(1, (h + 23) / 24 + 1) }
            return 31
        }()
        let startBound = Calendar.gmt.date(byAdding: .day, value: -(lookbackDays + 1), to: displayedDate) ?? displayedDate
        var cursor = startBound
        var dates: [Date] = []
        // displayedDate까지 forward iterate. 안전 한도 50.
        // 주의: RecurrenceRule.nextOccurrence(after:)는 referenceDate를 *포함* 검사 (이름과 달리).
        // cursor를 1일 advance해서 같은 occurrence 재반환 무한 루프 회피.
        while dates.count < 50 {
            guard let next = rule.nextOccurrence(after: cursor, startDate: startDate, endDate: recurrenceEndDate) else { break }
            if next > displayedDate { break }
            dates.append(next)
            guard let advanced = Calendar.gmt.date(byAdding: .day, value: 1, to: next) else { break }
            cursor = advanced
        }
        return dates
    }

    /// 이 NTD occurrence의 가장 최근 완료/포기 instant.
    /// 우선순위: 해당 occurrence의 RoutineCompletion.completedAt → (1회성) Item.completedAt.
    /// 둘 다 없으면 nil (= 아직 완료/포기 안 됨).
    func ntdLastCompletionInstant(on occurrenceDate: Date) -> Date? {
        if let rc = routineRecord(on: occurrenceDate), let ce = rc.completedAt {
            return ce
        }
        if recurrenceRule == nil,
           (itemStatus == .done || itemStatus == .failed),
           let ce = completedAt {
            return ce
        }
        return nil
    }

    /// `now` 기준 "현재 진행 중인 NTD occurrence"의 calendar date.
    /// 오늘 또는 어제(전날 시작 후 자정 넘어 진행 중인 경우)의 occurrence를 후보로 검사.
    /// 이미 RoutineCompletion 기록(성공/포기 무관)이 있는 occurrence는 스킵 — 카운트다운에서 빠짐.
    func ntdInProgressOccurrenceDate(at now: Date = Date()) -> Date? {
        let today: Date = .todayCalendarAnchor
        for offset in [0, -1] {
            guard let candidate = Calendar.gmt.date(byAdding: .day, value: offset, to: today),
                  ntdOccurs(on: candidate) else { continue }
            if hasRoutineRecord(on: candidate) { continue }
            if ntdState(on: candidate, now: now) == .inProgress {
                return candidate
            }
        }
        return nil
    }

    /// referenceDate부터 effectiveDueDate까지 남은 일수. 음수면 지남.
    /// referenceDate는 UTC anchor Date여야 한다 (기본값은 local 오늘의 UTC anchor).
    /// effectiveDueDate는 dueDate가 없으면 startDate로 fallback (단일 일정).
    func daysUntilDue(referenceDate: Date = .todayCalendarAnchor) -> Int? {
        guard let due = effectiveDueDate else { return nil }
        let from = Calendar.gmt.startOfDay(for: referenceDate)
        let to = Calendar.gmt.startOfDay(for: due)
        return Calendar.gmt.dateComponents([.day], from: from, to: to).day
    }

    func isOverdue(referenceDate: Date = .todayCalendarAnchor) -> Bool {
        guard recurrenceRule == nil else { return false }
        guard itemStatus == .pending, let days = daysUntilDue(referenceDate: referenceDate) else { return false }
        return days < 0
    }

    // MARK: - Routine helpers

    /// 특정 날짜에 이 루틴이 완료되었는지.
    /// date는 UTC anchor Date여야 한다 (RoutineCompletion.date도 UTC anchor로 저장됨).
    func isCompletedForDate(_ date: Date) -> Bool {
        let day = Calendar.gmt.startOfDay(for: date)
        let completions = (self.completions as? Set<RoutineCompletion>) ?? []
        return completions.contains { c in
            guard c.done, let d = c.date else { return false }
            return Calendar.gmt.isDate(d, inSameDayAs: day)
        }
    }

    /// referenceDate(포함) 이후 첫 occurrence까지의 일수.
    func daysUntilNextOccurrence(referenceDate: Date = .todayCalendarAnchor) -> Int? {
        guard let rule = recurrenceRule else { return nil }
        guard let next = rule.nextOccurrence(
            after: referenceDate,
            startDate: startDate,
            endDate: recurrenceEndDate
        ) else { return nil }
        let today = Calendar.gmt.startOfDay(for: referenceDate)
        return Calendar.gmt.dateComponents([.day], from: today, to: next).day
    }

    /// startDate ~ dueDate 사이 calendar day 수 (non-negative).
    /// 단일 모드(dueDate=nil) 또는 동일 날짜면 0. 1회성 multi-day period에도 같은 의미.
    /// 반복 항목의 각 occurrence는 (start ~ start+spanDays) 범위를 가진다고 derive.
    var spanDays: Int {
        guard let s = startDate, let d = dueDate else { return 0 }
        let days = Calendar.gmt.dateComponents([.day], from: s, to: d).day ?? 0
        return max(0, days)
    }

    /// `date`가 이 항목의 어떤 occurrence(또는 기간) 안에서 차지하는 위치.
    /// - 반복: rule.occurs(on:)가 true면 .start. (date-n)이 occurrence start이고 0<n<span이면 .middle, n==span이면 .end.
    /// - 1회성: startDate와 같으면 .start, dueDate와 같으면 .end, 사이면 .middle.
    /// - 어떤 occurrence/기간에도 안 걸리면 nil.
    /// 같은 날짜(start==due)인 1회성·반복은 .start 반환 (caller가 시각으로 라벨 결정).
    func occurrencePosition(on date: Date) -> OccurrencePosition? {
        let day = Calendar.gmt.startOfDay(for: date)
        if let rule = recurrenceRule, let anchor = startDate {
            let span = spanDays
            if span == 0 {
                return rule.occurs(on: day, startDate: anchor, endDate: recurrenceEndDate) ? .start : nil
            }
            // 후보 occurrence start = day - offset (offset ∈ [0, span])
            for offset in 0...span {
                guard let candidateStart = Calendar.gmt.date(byAdding: .day, value: -offset, to: day) else { continue }
                guard rule.occurs(on: candidateStart, startDate: anchor, endDate: recurrenceEndDate) else { continue }
                if offset == 0 { return .start }
                if offset == span { return .end }
                return .middle
            }
            return nil
        }
        // 1회성
        if let s = startDate, Calendar.gmt.isDate(s, inSameDayAs: day) {
            return .start
        }
        if let d = dueDate, Calendar.gmt.isDate(d, inSameDayAs: day) {
            return .end
        }
        if let s = startDate, let d = dueDate, s < day, day < d {
            return .middle
        }
        return nil
    }

    /// 현재 streak (연속 완료 일수). referenceDate부터 거꾸로 occurrence를 훑으며 done 여부 확인.
    func currentStreak(referenceDate: Date = .todayCalendarAnchor) -> Int {
        guard let rule = recurrenceRule else { return 0 }
        let completions = (self.completions as? Set<RoutineCompletion>) ?? []
        // 모든 완료 날짜를 UTC startOfDay set으로 모아 lookup.
        let doneDates = Set(completions.compactMap { c -> Date? in
            guard c.done, let d = c.date else { return nil }
            return Calendar.gmt.startOfDay(for: d)
        })

        var streak = 0
        var day = Calendar.gmt.startOfDay(for: referenceDate)
        var safety = 365
        while safety > 0 {
            if rule.occurs(on: day, startDate: startDate, endDate: recurrenceEndDate) {
                if doneDates.contains(day) {
                    streak += 1
                } else if !Calendar.gmt.isDate(day, inSameDayAs: referenceDate) {
                    // 오늘이 아닌데 미완료인 occurrence를 만나면 streak 종료.
                    // (오늘은 아직 안 한 상태일 수 있으므로 예외.)
                    break
                }
            }
            guard let prev = Calendar.gmt.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
            safety -= 1
        }
        return streak
    }

    /// NTD 자동 완성 처리.
    /// - 1회성 NTD: 목표시간 도달 시 Item.status=done (ListView 완료 섹션에 노출).
    /// - 반복 NTD: 각 occurrence가 끝났는데 기록(RoutineCompletion) 없으면 성공(done=true) 기록 생성.
    ///   Item.status는 유지 — rule이 계속 살아있음. dueDate(반복 종료일) 지나면
    ///   completeExpiredRoutines가 Item.status=done 처리 (Todo 루틴과 동일 패턴).
    /// - 미설정(한계까지) duration은 자동 완성 대상 X (사용자가 명시적 완료/포기해야 함).
    /// - 반복 NTD의 과거 occurrence 처리는 최근 7일만 검사 (앱 미실행 기간 보정).
    static func completeFinishedNTDs(in context: NSManagedObjectContext, now: Date = Date()) {
        let request: NSFetchRequest<Item> = Item.fetchRequest()
        request.predicate = NSPredicate(
            format: "kind == 1 AND status == 0 AND ntdDurationHour != nil"
        )
        do {
            let candidates = try context.fetch(request)
            for item in candidates {
                if item.recurrenceRule != nil {
                    processRecurringNTD(item, now: now, in: context)
                } else {
                    processOneOffNTD(item, now: now, in: context)
                }
            }
            if context.hasChanges {
                try context.save()
            }
        } catch {
            assertionFailure("completeFinishedNTDs failed: \(error)")
        }
    }

    private static func processOneOffNTD(_ item: Item, now: Date, in context: NSManagedObjectContext) {
        guard let occurrenceDate = item.startDate else { return }
        guard item.ntdState(on: occurrenceDate, now: now) == .ended else { return }
        // **createdAt floor**: 사용자가 startDate를 과거로 지정해 NTD 생성하면 ntdEndInstant가
        //   생성 시점 이전이라 즉시 auto-complete되는 버그 방지. 실제 종료가 생성 이후일 때만 처리.
        if let endInst = item.ntdEndInstant(on: occurrenceDate),
           let created = item.createdAt,
           endInst < created {
            return
        }
        // 중복 방지 — 이미 기록(성공/포기) 있으면 skip.
        if item.hasRoutineRecord(on: occurrenceDate) { return }
        // 1회성도 RoutineCompletion 생성 — 반복과 일관된 occurrence 기록 (활동 기록 표시).
        let endInstant = item.ntdEndInstant(on: occurrenceDate) ?? now
        let comp = RoutineCompletion(context: context)
        comp.id = UUID()
        comp.date = Calendar.gmt.startOfDay(for: occurrenceDate)
        comp.done = true
        comp.failed = false
        comp.completedAt = endInstant  // 계획된 종료 instant
        comp.item = item
        item.itemStatus = .done
        item.completedAt = endInstant
        item.updatedAt = now
        // OS 알림 취소 — 종료 알림은 이미 fire됐지만 미래 알림이 있을 수 있어 정리.
        item.cancelAllNotifications()
        ItemEvent.log(.completed, on: item, in: context)
    }

    private static func processRecurringNTD(_ item: Item, now: Date, in context: NSManagedObjectContext) {
        // 최근 7일치 occurrence 검사. 끝났는데 기록 없으면 done=true 기록 생성.
        // **createdAt floor**: 사용자가 startDate를 과거로 retroactive 변경 시 (e.g., 새 NTD startDate=5/19),
        //   item 생성일 이전 occurrence들이 lookback 윈도우에 들어가 false done 기록이 생성되는 버그 방지.
        //   occurrence의 종료 instant가 createdAt(item 생성 instant)보다 이전이면 skip — item이 존재하지
        //   않았던 시점에 종료된 occurrence는 auto-complete 대상 아님.
        let today: Date = .todayCalendarAnchor
        let existingRecords = (item.completions as? Set<RoutineCompletion>) ?? []
        for offset in 0...7 {
            guard let candidate = Calendar.gmt.date(byAdding: .day, value: -offset, to: today) else { continue }
            guard item.ntdOccurs(on: candidate) else { continue }
            // 종료 instant가 createdAt 이전이면 skip.
            if let endInst = item.ntdEndInstant(on: candidate),
               let created = item.createdAt,
               endInst < created {
                continue
            }
            guard item.ntdState(on: candidate, now: now) == .ended else { continue }
            // 이미 기록(성공/포기) 있으면 skip.
            let alreadyRecorded = existingRecords.contains { c in
                guard let d = c.date else { return false }
                return Calendar.gmt.isDate(d, inSameDayAs: candidate)
            }
            if alreadyRecorded { continue }
            // 성공 기록 생성.
            let comp = RoutineCompletion(context: context)
            comp.id = UUID()
            comp.date = Calendar.gmt.startOfDay(for: candidate)
            comp.done = true
            comp.failed = false
            comp.completedAt = item.ntdEndInstant(on: candidate) ?? now  // 계획된 종료 instant
            comp.item = item
            item.updatedAt = now
            ItemEvent.log(.completed, on: item, in: context)
        }
    }

    /// 반복 routine의 status를 양방향으로 동기화.
    ///
    /// 정확한 조건: 마지막 occurrence start + spanDays < today → done.
    /// = `rule.nextOccurrence(after: today - spanDays, endDate: recurrenceEndDate)` 가 nil이면 done.
    ///   nextOccurrence(after:)는 referenceDate를 *포함* 검사하므로 pivot이 occurrence이면 그것을 반환 →
    ///   그 occurrence가 today에 종료되거나 그 이후까지 진행 중 → not done.
    ///   recurrenceEndDate=nil이면 무한 반복 → nextOccurrence가 항상 미래 occurrence 반환 → not done.
    ///
    /// **양방향 처리** — status=0/1 routine 모두 검사 (recurrenceEndDate 유무 무관):
    /// - .pending인데 새 알고리즘상 done이어야 → .done 처리 (cancelAllNotifications + log .completed)
    /// - .done인데 새 알고리즘상 not done이어야 → .pending 복원 (syncNotifications + log .uncompleted)
    /// 사용자가 recurrenceEndDate를 미래로 변경/제거하는 경우 저장 trigger로 자동 동기화.
    /// routine은 명시적 .done UI가 없어 모두 자동 처리 — 의도와 자동의 구분 문제 없음.
    static func completeExpiredRoutines(in context: NSManagedObjectContext, now: Date = Date()) {
        let today = now.calendarDateAnchor
        let request: NSFetchRequest<Item> = Item.fetchRequest()
        request.predicate = NSPredicate(
            format: "recurrenceRule != nil AND (status == 0 OR status == 1)"
        )
        do {
            let candidates = try context.fetch(request)
            for item in candidates {
                guard let rule = item.recurrenceRule,
                      let startAnchor = item.startDate
                else { continue }
                guard let pivot = Calendar.gmt.date(byAdding: .day, value: -item.spanDays, to: today)
                else { continue }
                let nextStart = rule.nextOccurrence(
                    after: pivot,
                    startDate: startAnchor,
                    endDate: item.recurrenceEndDate
                )
                let shouldBeDone = (nextStart == nil)
                let currentlyDone = (item.itemStatus == .done)
                if shouldBeDone && !currentlyDone {
                    item.itemStatus = .done
                    item.completedAt = now
                    item.updatedAt = now
                    item.cancelAllNotifications()
                    ItemEvent.log(.completed, on: item, in: context)
                } else if !shouldBeDone && currentlyDone {
                    item.itemStatus = .pending
                    item.completedAt = nil
                    item.updatedAt = now
                    item.syncNotifications()
                    ItemEvent.log(.uncompleted, on: item, in: context)
                }
            }
            if context.hasChanges {
                try context.save()
            }
        } catch {
            assertionFailure("completeExpiredRoutines failed: \(error)")
        }
    }

    // MARK: - 알림 (Local Notifications)
    //
    // ID 체계: "{Reminder.id.uuidString}:{occurrenceDate yyyyMMdd}" — 1 Reminder당 N개 OS notification.
    // - 1회성: occurrence 1개 → notification 1개
    // - routine: 다음 N개 occurrence × Reminder 수 → 그만큼 등록
    // anchor + offset으로 fire 시각 계산, wall-clock semantics (timezone 미설정 components).
    // 호출 지점: AddItemView.save / delete, NTDRow.giveUp, auto-complete, scenePhase 복귀 시 refill 등.

    /// routine 알림을 미리 등록할 future occurrence 수.
    /// iOS pending notification 상한(앱 전체 64개) 고려해 보수적으로 4개 선택 —
    /// 4개 routine × 2 anchor × 4 occurrence = 32개. scenePhase 복귀마다 refill.
    private static let notificationOccurrenceWindow = 4

    /// 현재 reminders 기반으로 OS 알림 재등록.
    /// routine은 다음 N개 occurrence 일괄 등록 (anchor 1회만 등록되던 기존 버그 fix).
    /// 기존 등록은 prefix 매칭으로 일괄 cancel → orphan 방지.
    func syncNotifications() {
        let reminderSet = (reminders as? Set<Reminder>) ?? []
        let prefixes = reminderSet.compactMap { $0.id?.uuidString.appending(":") }
        let titleText = title ?? ""
        let now = Date()
        let occurrences = nextOccurrenceDates(from: now.calendarDateAnchor,
                                              maxCount: Self.notificationOccurrenceWindow)
        // 1회성·routine 공통으로 처리하기 위해 sync에서는 occurrences 배열만 사용.
        // 1회성은 nextOccurrenceDates가 startDate 1개를 반환 (또는 빈 배열).
        // Reminder의 fire instant 계산은 occurrence별로 다르므로 inner loop.
        // 이미 완료/포기된 occurrence는 알림 등록 skip — refresh 시 cancelled 알림 재등록 방지.
        // 버그: 어제 시작 multi-day NTD 포기 → cancelNotifications(forOccurrence:)로 즉시 cancel됐지만,
        // 다음 scenePhase=.active 시 refreshAllRoutineNotifications → syncNotifications가 다시 등록 →
        // 종료 시각에 "성공" 알림 fire. 이 가드로 해결.
        let finishedOccurrences: Set<String> = {
            let comps = (completions as? Set<RoutineCompletion>) ?? []
            var set = Set<String>()
            for rc in comps {
                guard let d = rc.date, (rc.done || rc.failed) else { continue }
                set.insert(Self.occurrenceIDStamp(for: d))
            }
            return set
        }()
        // 1회성 NTD/Todo가 명시적 status로 done/failed 된 경우도 skip.
        let itemFinished = (itemStatus == .done || itemStatus == .failed)
        Task {
            await NotificationService.shared.cancel(matchingPrefixes: prefixes)
            guard !itemFinished else { return }  // 1회성 완료/포기면 모든 알림 등록 skip
            for reminder in reminderSet {
                guard let rid = reminder.id?.uuidString else { continue }
                for occDate in occurrences {
                    let stamp = Self.occurrenceIDStamp(for: occDate)
                    if finishedOccurrences.contains(stamp) { continue }
                    guard let fireDate = notificationFireDate(
                        for: reminder, occurrenceDate: occDate
                    ) else { continue }
                    guard fireDate > now else { continue }
                    let triggerComps = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute],
                        from: fireDate
                    )
                    let occID = "\(rid):\(stamp)"
                    NotificationService.shared.schedule(
                        id: occID,
                        title: titleText,
                        body: notificationBody(for: reminder),
                        components: triggerComps
                    )
                }
            }
        }
    }

    /// Item의 모든 OS 알림 취소 — Reminder당 다수 occurrence ID를 가질 수 있으므로 prefix 일괄.
    func cancelAllNotifications() {
        let comps = (reminders as? Set<Reminder>) ?? []
        let prefixes = comps.compactMap { $0.id?.uuidString.appending(":") }
        guard !prefixes.isEmpty else { return }
        Task {
            await NotificationService.shared.cancel(matchingPrefixes: prefixes)
        }
    }

    /// 단일 Reminder id에 대한 모든 occurrence 알림 일괄 취소.
    /// AddItemView.reconcileReminders에서 Reminder 레코드 삭제 직전 호출 — orphan 방지.
    static func cancelNotifications(forReminderID rid: UUID) {
        let prefix = rid.uuidString + ":"
        Task {
            await NotificationService.shared.cancel(matchingPrefixes: [prefix])
        }
    }

    /// 특정 occurrence(reminders 전부)의 알림만 취소.
    /// 사용처:
    ///   - NTD 포기: 그 occurrence의 시작/종료 알림 cancel (다음 occurrence는 보존)
    ///   - 반복 Todo/습관 미리 체크: 그 occurrence 알림 cancel
    /// ID 패턴: `{Reminder.id}:{yyyyMMdd}` — 해당 occurrence 정확히 match.
    func cancelNotifications(forOccurrence occurrenceDate: Date) {
        let stamp = Item.occurrenceIDStamp(for: occurrenceDate)
        let reminders = (self.reminders as? Set<Reminder>) ?? []
        let ids = reminders.compactMap { r -> String? in
            guard let rid = r.id?.uuidString else { return nil }
            return "\(rid):\(stamp)"
        }
        guard !ids.isEmpty else { return }
        NotificationService.shared.cancel(ids: ids)
    }

    /// 모든 Item의 reminders 중 같은 anchor에 중복된 레코드를 1개만 남기고 정리.
    /// CloudKit 동기화 충돌 등으로 같은 anchor에 reminder가 누적되면 OS 알림이 N개 fire되는 문제를 방지.
    /// 정리 시 stale reminder의 OS 알림은 prefix 일괄 cancel + Core Data에서 삭제.
    /// 변경이 있을 때만 save + 남은 reminder로 알림 재동기화.
    static func dedupeReminders(in context: NSManagedObjectContext) {
        let request: NSFetchRequest<Item> = Item.fetchRequest()
        do {
            let items = try context.fetch(request)
            var changed = false
            for item in items {
                let reminders = (item.reminders as? Set<Reminder>) ?? []
                var buckets: [Int16: [Reminder]] = [:]
                for r in reminders { buckets[r.anchor, default: []].append(r) }
                for (_, group) in buckets where group.count > 1 {
                    let sorted = group.sorted {
                        ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
                    }
                    for dup in sorted.dropFirst() {
                        if let rid = dup.id {
                            Item.cancelNotifications(forReminderID: rid)
                        }
                        context.delete(dup)
                        changed = true
                    }
                }
            }
            if changed {
                try context.save()
                refreshAllRoutineNotifications(in: context)
            }
        } catch {
            assertionFailure("dedupeReminders failed: \(error)")
        }
    }

    /// 모든 active(status=0) routine의 알림을 재등록 — scenePhase 복귀 시 refill.
    /// 과거 fire 후 빠진 미래 occurrence 슬롯을 채워 long-term routine이 끊기지 않게 함.
    static func refreshAllRoutineNotifications(in context: NSManagedObjectContext) {
        let request: NSFetchRequest<Item> = Item.fetchRequest()
        request.predicate = NSPredicate(
            format: "recurrenceRule != nil AND status == 0 AND reminders.@count > 0"
        )
        do {
            let routines = try context.fetch(request)
            for item in routines { item.syncNotifications() }
        } catch {
            assertionFailure("refreshAllRoutineNotifications failed: \(error)")
        }
    }

    /// 알림 ID에 사용할 occurrence stamp — UTC anchor 기준 yyyyMMdd.
    /// timezone 영향 차단해 같은 occurrence가 항상 같은 stamp를 갖도록 보장.
    private static func occurrenceIDStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return formatter.string(from: date)
    }

    /// 알림 스케줄용 다음 occurrence 날짜 목록 (UTC anchor).
    /// - 1회성: startDate가 today 이상이면 1개, 아니면 빈 배열.
    /// - routine: nextOccurrence를 maxCount만큼 forward iterate.
    func nextOccurrenceDates(from referenceDate: Date, maxCount: Int) -> [Date] {
        if let rule = recurrenceRule {
            var dates: [Date] = []
            // referenceDate 자체도 occurrence면 포함하기 위해 하루 전부터 시작.
            var cursor = Calendar.gmt.date(byAdding: .day, value: -1, to: referenceDate) ?? referenceDate
            while dates.count < maxCount {
                guard let next = rule.nextOccurrence(
                    after: cursor,
                    startDate: startDate,
                    endDate: recurrenceEndDate
                ) else { break }
                dates.append(next)
                cursor = next
            }
            return dates
        }
        // 1회성 — startDate가 today 이후(또는 같음)면 1회 등록 대상.
        guard let s = startDate else { return [] }
        let todayStart = Calendar.gmt.startOfDay(for: referenceDate)
        return s >= todayStart ? [s] : []
    }

    /// 특정 occurrence에서 reminder의 fire 시각.
    /// anchor + offset으로 instant 계산. occurrenceDate가 routine의 그 occurrence anchor.
    func notificationFireDate(for reminder: Reminder, occurrenceDate: Date) -> Date? {
        let anchor = ReminderAnchor(rawValue: reminder.anchor) ?? .absolute
        let offset = Int(reminder.offsetMin)
        switch anchor {
        case .absolute:
            return reminder.fireDate
        case .start:
            guard let base = occurrenceStartInstant(on: occurrenceDate) else { return nil }
            return Calendar.current.date(byAdding: .minute, value: offset, to: base)
        case .due:
            guard let base = occurrenceEndInstant(on: occurrenceDate) else { return nil }
            return Calendar.current.date(byAdding: .minute, value: offset, to: base)
        }
    }

    /// occurrence의 시작 instant (start anchor).
    /// - NTD: ntdStartInstant(on:) — startHour wall-clock + occurrenceDate (y,m,d)
    /// - Todo: occurrenceDate + startHour. hour는 항상 0~23 (default 0).
    func occurrenceStartInstant(on occurrenceDate: Date) -> Date? {
        if itemKind == .notTodo {
            return ntdStartInstant(on: occurrenceDate)
        }
        return Self.localInstant(fromCalendarDate: occurrenceDate, hour: startHourInt)
    }

    /// occurrence의 종료 instant (due anchor).
    /// - NTD: ntdEndInstant(on:) — startHour + duration
    /// - Todo: (occurrenceDate + spanDays) + dueHour. hour는 0~24 (24=다음 날 0시).
    func occurrenceEndInstant(on occurrenceDate: Date) -> Date? {
        if itemKind == .notTodo {
            return ntdEndInstant(on: occurrenceDate)
        }
        let span = spanDays
        let endDay: Date = (span > 0
            ? (Calendar.gmt.date(byAdding: .day, value: span, to: occurrenceDate) ?? occurrenceDate)
            : occurrenceDate)
        return Self.localInstant(fromCalendarDate: endDay, hour: dueHourInt)
    }

    /// 알림 body 텍스트 — kind + anchor + offset에 따라 분기.
    /// 정시: "마감 시각입니다" / "목표 달성!" / "시작 시간입니다"
    /// 사전: "10분 후 마감입니다" 등
    func notificationBody(for reminder: Reminder) -> String {
        let anchor = ReminderAnchor(rawValue: reminder.anchor) ?? .absolute
        let offset = Int(reminder.offsetMin)  // 음수=사전, 0=정시
        let minutesBefore = max(0, -offset)
        let isExact = (offset == 0)
        if itemKind == .notTodo {
            switch anchor {
            case .start:
                return isExact
                    ? String(localized: "notif.body.ntd.start")
                    : String.localizedStringWithFormat(
                        NSLocalizedString("notif.body.ntd.start_before", comment: ""),
                        minutesBefore
                      )
            case .due:
                return isExact
                    ? String(localized: "notif.body.ntd.end")
                    : String.localizedStringWithFormat(
                        NSLocalizedString("notif.body.ntd.end_before", comment: ""),
                        minutesBefore
                      )
            case .absolute:
                return ""
            }
        }
        // Todo — 시간 미지정: offset이 "자정 기준 분"(절대 시각/사전일)이라 "X분 후/전" 표현 부적절.
        // 시작일 당일 알림(offset>=0)이면 "오늘", 이전 일자 알림(offset<0)이면 "예정된" 으로 안내.
        if !hasExplicitTime {
            return offset >= 0
                ? String(localized: "notif.body.todo.today")
                : String(localized: "notif.body.todo.upcoming")
        }
        // Todo (시간 지정)
        if anchor == .due {
            return isExact
                ? String(localized: "notif.body.todo.due")
                : String.localizedStringWithFormat(
                    NSLocalizedString("notif.body.todo.due_before", comment: ""),
                    minutesBefore
                  )
        }
        if anchor == .start {
            return isExact
                ? String(localized: "notif.body.todo.start")
                : String.localizedStringWithFormat(
                    NSLocalizedString("notif.body.todo.start_before", comment: ""),
                    minutesBefore
                  )
        }
        return ""
    }

    @discardableResult
    static func make(
        in context: NSManagedObjectContext,
        kind: ItemKind = .todo,
        title: String,
        priority: Priority = .none
    ) -> Item {
        let now = Date()
        let item = Item(context: context)
        item.id = UUID()
        item.title = title
        item.itemKind = kind
        item.itemPriority = priority
        item.itemStatus = .pending
        item.createdAt = now  // instant
        item.updatedAt = now  // instant
        return item
    }

    // MARK: - 활동 occurrence accessor / 증가

    /// 활동 occurrence의 현재 누적값. occurrenceDate에 해당하는 RC.valueRecorded.
    /// RC 없으면 0.
    func activityCurrentValue(on occurrenceDate: Date) -> Int {
        guard let rc = routineRecord(on: occurrenceDate) else { return 0 }
        return Int(rc.valueRecorded?.doubleValue ?? 0)
    }

    /// 그 occurrence에 적용된 실제 target — RC.targetSnapshot 우선, 없으면 item의 현재 target.
    /// 사용자가 target 변경 시 RC의 snapshot은 보존(done/failed 시) 또는 동기화(미완료)되어 과거 진행률
    /// 일관성 유지. 진행률 계산/완료 판정 모두 이 함수 결과로.
    func effectiveTargetValue(on occurrenceDate: Date) -> Double? {
        if let snap = routineRecord(on: occurrenceDate)?.targetSnapshot?.doubleValue, snap > 0 {
            return snap
        }
        return activityTargetValueDouble
    }

    /// RC의 targetSnapshot을 item의 현재 target으로 sync — RC가 미완료(done=false && failed=false)일 때만.
    /// 완료/포기 후 target 변경은 RC snapshot 보존.
    fileprivate static func syncTargetSnapshot(_ rc: RoutineCompletion, item: Item) {
        if rc.done || rc.failed { return }  // 완료/포기 RC는 보존
        rc.targetSnapshot = item.activityTargetValue
    }

    /// 활동 occurrence에 N만큼 증가. RC 없으면 생성. target 도달 시 done=true 자동 flip.
    /// 1회성 활동(recurrenceRule=nil)도 같은 RC 패턴 — 활동 기록·일관성 위해.
    /// 호출 측에서 context.save() 책임.
    /// 반환값: 이번 증가로 **새로** target에 도달했으면 true (목표 달성 알림 트리거용).
    @discardableResult
    static func incrementActivityValue(
        for item: Item,
        by amount: Int,
        occurrenceDate: Date,
        in context: NSManagedObjectContext
    ) -> Bool {
        let now = Date()
        let day = Calendar.gmt.startOfDay(for: occurrenceDate)
        let completions = (item.completions as? Set<RoutineCompletion>) ?? []
        let existing = completions.first { c in
            guard let d = c.date else { return false }
            return Calendar.gmt.isDate(d, inSameDayAs: day)
        }
        let rc: RoutineCompletion
        if let existing {
            rc = existing
        } else {
            rc = RoutineCompletion(context: context)
            rc.id = UUID()
            rc.date = day
            rc.item = item
            rc.failed = false
        }
        let wasDone = rc.done
        let prev = Int(rc.valueRecorded?.doubleValue ?? 0)
        let next = max(prev + amount, 0)
        rc.valueRecorded = NSNumber(value: Double(next))
        // RC의 target snapshot 동기화 — 미완료 RC만. done/failed RC는 보존.
        syncTargetSnapshot(rc, item: item)
        // target 도달 — done=true 자동. 이미 done이면 그대로 (초과 누적 허용).
        // 판정은 RC.targetSnapshot 기준 (사용자가 target 변경해도 그 시점의 평가 보존).
        let effectiveTarget = rc.targetSnapshot?.doubleValue ?? item.activityTargetValueDouble ?? 0
        if effectiveTarget > 0, Double(next) >= effectiveTarget, !rc.done {
            rc.done = true
        }
        // completedAt은 활동 record에서 "마지막 업데이트 시각" 의미로 사용 — 정렬에서 최신 활동이 위로.
        // progress record(미완성)에도 갱신 — 안 그러면 nil로 sort 시 맨 아래로 가버림.
        rc.completedAt = now
        // 1회성 활동의 Item.status sync — target 도달 시 done, 그 외 pending.
        if item.recurrenceRule == nil {
            if rc.done {
                item.itemStatus = .done
                item.completedAt = now
            } else {
                item.itemStatus = .pending
                item.completedAt = nil
            }
        }
        item.updatedAt = now
        return rc.done && !wasDone
    }

    // MARK: - Row 공용 view 헬퍼
    //
    // ItemRow / MissionRow 양쪽에서 동일하게 쓰던 작은 view-state 헬퍼 — 중복 제거 차원에서 Item 확장으로 이전.
    // 순수 model 헬퍼지만 view layer가 즉시 보고 부르는 의미라 별도 file로 분리하진 않음.

    /// 반복 패턴 요약 — `repeat` 아이콘과 함께 statusIcons에 표시. recurrenceRule 없으면 nil.
    var recurrenceTextSummary: String? {
        guard let rule = recurrenceRule else { return nil }
        return rule.summaryText()
    }

    /// 예약된 알림 1개 이상 보유 여부 — `bell` 아이콘 노출 판정.
    var hasReminders: Bool {
        guard let set = reminders as? Set<Reminder> else { return false }
        return !set.isEmpty
    }

    /// 반복 항목의 현재 streak 일수. 반복 아니거나 streak 0이면 nil.
    /// `referenceDate` 기본값: `.todayCalendarAnchor`. row의 `referenceDate` 그대로 전달 가능.
    func streakValueIfRoutine(referenceDate: Date = .todayCalendarAnchor) -> Int? {
        guard recurrenceRule != nil else { return nil }
        let s = currentStreak(referenceDate: referenceDate)
        return s > 0 ? s : nil
    }

    // MARK: - Report stats (MissionReportView)

    /// MissionReportView 상단 6 카드 통계 묶음.
    /// 단일 forward iteration (시작일 ~ 오늘)으로 totalOccurrences/maxStreak/monthly/yearly 일괄 계산 — RC 수천건도 ms 수준.
    /// currentStreak은 기존 backward 함수 재사용 (today 예외 로직 동일 정책).
    struct ReportStats {
        let currentStreak: Int
        let maxStreak: Int
        let totalCompletions: Int
        let monthCompletions: Int    // 이번달 done — rc.date(occurrence 시작일) 기준
        let yearCompletions: Int     // 올해 done — 동일 기준
        let totalOccurrences: Int    // 시작일~오늘(양끝 포함) 사이 rule.occurs(...)=true 일수
        let daysSinceStart: Int      // 시작일~오늘 일수 차이 (start==today면 0)

        /// 달성률 0.0~1.0. occurrence 0이면 0.
        var completionRate: Double {
            guard totalOccurrences > 0 else { return 0 }
            return Double(totalCompletions) / Double(totalOccurrences)
        }
    }

    /// 반복 항목 전용 통계 계산. 비-반복이면 모든 값 0인 stats 반환 (호출 측에서 가드 권장).
    func reportStats(referenceDate: Date = .todayCalendarAnchor) -> ReportStats {
        let utc = Calendar.gmt
        let today = utc.startOfDay(for: referenceDate)
        let start = utc.startOfDay(for: startDate ?? referenceDate)
        let daysSince = utc.dateComponents([.day], from: start, to: today).day ?? 0

        guard let rule = recurrenceRule else {
            return ReportStats(currentStreak: 0, maxStreak: 0, totalCompletions: 0,
                               monthCompletions: 0, yearCompletions: 0,
                               totalOccurrences: 0, daysSinceStart: max(daysSince, 0))
        }

        // done occurrence date set — O(1) lookup.
        let completions = (self.completions as? Set<RoutineCompletion>) ?? []
        let doneDates = Set(completions.compactMap { rc -> Date? in
            guard rc.done, let d = rc.date else { return nil }
            return utc.startOfDay(for: d)
        })

        let currentMonth = utc.component(.month, from: today)
        let currentYear = utc.component(.year, from: today)

        var totalOccurrences = 0
        var totalDone = 0
        var monthDone = 0
        var yearDone = 0
        var maxStreak = 0
        var runStreak = 0

        var day = start
        var safety = 365 * 10  // 10년 cap — 현실 사용에 충분.
        while day <= today, safety > 0 {
            if rule.occurs(on: day, startDate: startDate, endDate: recurrenceEndDate) {
                totalOccurrences += 1
                if doneDates.contains(day) {
                    totalDone += 1
                    runStreak += 1
                    if runStreak > maxStreak { maxStreak = runStreak }
                    let y = utc.component(.year, from: day)
                    if y == currentYear {
                        yearDone += 1
                        let m = utc.component(.month, from: day)
                        if m == currentMonth { monthDone += 1 }
                    }
                } else if !utc.isDate(day, inSameDayAs: today) {
                    // 오늘 미완료는 streak 종료 X (사용자가 아직 할 수 있음).
                    runStreak = 0
                }
            }
            guard let next = utc.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            safety -= 1
        }

        return ReportStats(
            currentStreak: currentStreak(referenceDate: referenceDate),
            maxStreak: maxStreak,
            totalCompletions: totalDone,
            monthCompletions: monthDone,
            yearCompletions: yearDone,
            totalOccurrences: totalOccurrences,
            daysSinceStart: max(daysSince, 0)
        )
    }

    // MARK: - Migration (출시 후 제거 예정)
    //
    // 기존 RC들에 targetSnapshot이 nil인 경우 item의 현재 target 값으로 채움.
    // 앱 launch 시 1회 실행 (UserDefaults `migrated.rc_target_snapshot` 플래그).
    // 출시 후엔 nil RC가 더 이상 발생 안 함 → 이 함수 + 호출 + 플래그 삭제 예정.

    static func backfillRCTargetSnapshots(in context: NSManagedObjectContext) {
        let request: NSFetchRequest<RoutineCompletion> = RoutineCompletion.fetchRequest()
        request.predicate = NSPredicate(format: "targetSnapshot == nil")
        guard let rcs = try? context.fetch(request), !rcs.isEmpty else { return }
        for rc in rcs {
            guard let item = rc.item, let target = item.activityTargetValue else { continue }
            rc.targetSnapshot = target
        }
        if context.hasChanges {
            do { try context.save() } catch {
                assertionFailure("backfillRCTargetSnapshots save failed: \(error)")
            }
        }
    }
}
