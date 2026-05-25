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
    //
    // ntdStartHour는 deprecate — startHour로 통합. 기존 스키마는 유지 (사용 안 함).

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

    /// 시간 명시 여부 — `dueHourInt < 24`면 사용자가 종료 시각을 설정.
    var hasExplicitTime: Bool { dueHourInt < 24 }

    var ntdDurationHourInt: Int? {
        get { ntdDurationHour?.intValue }
        set { ntdDurationHour = newValue.map(NSNumber.init(value:)) }
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

    /// 단일 일정 판정 — startDate==dueDate 같은 날 + (시간 미설정 OR startHour==dueHour).
    /// 사용자 정의:
    ///   - 같은 날 + dueHour==24 (시간 미설정 종일): 단일
    ///   - 같은 날 + startHour==dueHour: 단일 (시간 있는 단일)
    ///   - 다른 날 또는 같은 날 + startH<dueH: 기간
    var isSingleSchedule: Bool {
        guard let s = startDate, let d = dueDate else { return true }
        if !Calendar.gmt.isDate(s, inSameDayAs: d) { return false }
        if !hasExplicitTime { return true }
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
        if let d = dueInst, now < d { return d }
        return nil
    }

    /// 진행 중 판정 — 적용 occurrence 시작 instant 후 + 종료 instant 전.
    /// 라벨/체크박스 색상(푸른 라인) 등 시각 피드백 공통 helper.
    /// - 1회성 단일 시각 미설정: 0시~24시(=다음날 0시) → 종일 진행 중
    /// - 1회성 단일 시각 있음(s==e): 진행 중 instant 사실상 없음 → false
    /// - 1회성 기간/반복: occurrence 범위 안이면 진행 중
    func isInProgress(viewDate: Date, now: Date) -> Bool {
        guard let occStart = referenceOccurrenceStartDate(viewDate: viewDate) else { return false }
        let span = recurrenceRule != nil ? spanDays : 0
        let occDueDay: Date = (recurrenceRule != nil)
            ? (Calendar.gmt.date(byAdding: .day, value: span, to: occStart) ?? occStart)
            : (effectiveDueDate ?? occStart)
        let startInst = Item.localInstant(fromCalendarDate: occStart, hour: startHourInt)
        let dueInst = Item.localInstant(fromCalendarDate: occDueDay, hour: dueHourInt)
        if let s = startInst, now < s { return false }
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
        let cursor = Calendar.gmt.date(byAdding: .day, value: -1, to: viewDate) ?? viewDate
        return rule.nextOccurrence(after: cursor, startDate: startDate, endDate: recurrenceEndDate)
    }

    /// 1회성 Todo 섹션 분류 (TodayView / ItemRow 공유 helper).
    /// - **단일**: 시작 instant 전 → 시작, 이후 → 진행 중 (마감 섹션 안 감)
    /// - **기간**: 시작 전 → 시작, 종료일 → 마감, 중간 → 진행, 종료일 이후 → nil
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
    /// 편집 화면 "활동 기록" section 표시용. Todo routine + NTD(1회성·반복) 공통.
    /// 빈 RoutineCompletion(done=false, failed=false)은 의미 없으므로 제외.
    /// completedAt이 nil인 legacy record는 record.date로 fallback 정렬.
    var routineHistoryRecords: [RoutineCompletion] {
        let comps = (completions as? Set<RoutineCompletion>) ?? []
        return comps
            .filter { $0.done || $0.failed }
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
    ///   - duration 없음 + RC 기록(완료/포기) 있음: RC.completedAt (사용자 종료 시점)
    ///   - duration 없음 + 1회성 종료(Item.status done/failed): item.completedAt
    ///   - duration 없음 + 진행 중: now (계속 확장 — "현재까지 진행시간")
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
        // displayedDate까지 forward iterate. 안전 한도 50 — 보통 lookback 일수 내 occurrence 개수.
        while dates.count < 50 {
            guard let next = rule.nextOccurrence(after: cursor, startDate: startDate, endDate: recurrenceEndDate) else { break }
            if next > displayedDate { break }
            dates.append(next)
            cursor = next
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
        let today: Date = .todayCalendarAnchor
        let existingRecords = (item.completions as? Set<RoutineCompletion>) ?? []
        for offset in 0...7 {
            guard let candidate = Calendar.gmt.date(byAdding: .day, value: -offset, to: today) else { continue }
            guard item.ntdOccurs(on: candidate) else { continue }
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

    /// recurrenceEndDate가 지난 routine을 자동으로 done 처리.
    ///
    /// Multi-day occurrence(spanDays>0) 고려:
    ///   anchor 5/24, dueDate 5/27 (span=3), recurrenceEndDate 5/25인 routine은
    ///   5/24 occurrence가 5/27까지 자연 종료되어야 함. recurrenceEndDate 단독 비교만으로 자동 완료하면
    ///   5/26부터 status=done 되어 occurrence가 미리 사라짐.
    ///   → 마지막 occurrence 종료일 = recurrenceEndDate + spanDays. today가 그보다 커야 자동 완료.
    ///
    /// 1단계 fetch는 over-broad(`recurrenceEndDate < today`), 2단계 Swift filter로 span 보정.
    /// NSPredicate에서 Date 산술 불가하므로 in-memory filter.
    static func completeExpiredRoutines(in context: NSManagedObjectContext, now: Date = Date()) {
        let today = now.calendarDateAnchor
        let request: NSFetchRequest<Item> = Item.fetchRequest()
        request.predicate = NSPredicate(
            format: "recurrenceRule != nil AND status == 0 AND recurrenceEndDate != nil AND recurrenceEndDate < %@",
            today as NSDate
        )
        do {
            let candidates = try context.fetch(request)
            let expired = candidates.filter { item in
                guard let end = item.recurrenceEndDate else { return false }
                // span=0인 경우(단일 day 또는 NTD)는 recurrenceEndDate < today만으로 충분.
                // span>0이면 마지막 occurrence가 진행 중일 수 있으니 (end + span) < today 확인.
                guard let lastDay = Calendar.gmt.date(byAdding: .day, value: item.spanDays, to: end)
                else { return false }
                return today > lastDay
            }
            guard !expired.isEmpty else { return }
            for item in expired {
                item.itemStatus = .done
                item.completedAt = now
                item.updatedAt = now
                item.cancelAllNotifications()
                ItemEvent.log(.completed, on: item, in: context)
            }
            try context.save()
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
        Task {
            await NotificationService.shared.cancel(matchingPrefixes: prefixes)
            for reminder in reminderSet {
                guard let rid = reminder.id?.uuidString else { continue }
                for occDate in occurrences {
                    guard let fireDate = notificationFireDate(
                        for: reminder, occurrenceDate: occDate
                    ) else { continue }
                    guard fireDate > now else { continue }
                    let triggerComps = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute],
                        from: fireDate
                    )
                    let occID = "\(rid):\(Self.occurrenceIDStamp(for: occDate))"
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
        // Todo
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
}
