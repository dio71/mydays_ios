import CoreData
import Foundation

extension RecurrenceRule {

    // MARK: - frequency

    var itemFrequency: Frequency {
        get { Frequency(rawValue: frequency) ?? .daily }
        set { frequency = newValue.rawValue }
    }

    // MARK: - weekday (Calendar.weekday: 1=Sun ... 7=Sat → bit 0=Sun, bit 6=Sat)

    var selectedWeekdays: Set<Int> {
        var set: Set<Int> = []
        for w in 1...7 where (weekdayMask & (Int16(1) << (w - 1))) != 0 {
            set.insert(w)
        }
        return set
    }

    func setSelectedWeekdays(_ weekdays: Set<Int>) {
        var mask: Int16 = 0
        for w in weekdays {
            mask |= Int16(1) << (w - 1)
        }
        weekdayMask = mask
    }

    // MARK: - day of month (bit 0=1일 … bit 30=31일, bit 31=말일)

    static let lastDayBit: Int64 = Int64(1) << 31

    var selectedDays: Set<Int> {
        var set: Set<Int> = []
        for d in 1...31 where (dayOfMonthMask & (Int64(1) << (d - 1))) != 0 {
            set.insert(d)
        }
        return set
    }

    func setSelectedDays(_ days: Set<Int>) {
        var mask: Int64 = dayOfMonthMask & Self.lastDayBit
        for d in days {
            mask |= Int64(1) << (d - 1)
        }
        dayOfMonthMask = mask
    }

    var includesLastDay: Bool {
        get { (dayOfMonthMask & Self.lastDayBit) != 0 }
        set {
            if newValue { dayOfMonthMask |= Self.lastDayBit }
            else        { dayOfMonthMask &= ~Self.lastDayBit }
        }
    }

    // MARK: - weekday ordinal (조건지정: N번째 weekday / N번째 날)
    //
    // weekdayOrdinal 의미:
    //   1~5: 첫번째 ~ 다섯번째 (해당 월 안에서 N번째)
    //   -1: 마지막 (last)
    //   nil: 조건지정 미사용 (일자지정 모드)
    //
    // weekdayMask와 조합:
    //   ordinal != nil + weekdayMask != 0 → "N번째 [요일]" (예: 첫번째 월요일)
    //   ordinal != nil + weekdayMask == 0 → "N번째 날" (예: 두번째 날=2일, 마지막 날=말일)
    //
    // Legacy `includesLastDay`는 조건지정 도입 전 "말일 toggle"을 위한 필드 — 호환 위해 occurs에서 함께 평가.

    static let lastOrdinalSentinel: Int = -1

    /// 사용자 코드용 — NSNumber? ↔ Int? 변환.
    var weekdayOrdinalValue: Int? {
        get { weekdayOrdinal.map { Int(truncating: $0) } }
        set { weekdayOrdinal = newValue.map { NSNumber(value: Int16($0)) } }
    }

    // MARK: - month (1~12 → bit 0~11, mask 0 = 모든 월)

    var selectedMonths: Set<Int> {
        if monthMask == 0 { return Set(1...12) }
        var set: Set<Int> = []
        for m in 1...12 where (monthMask & (Int16(1) << (m - 1))) != 0 {
            set.insert(m)
        }
        return set
    }

    func setSelectedMonths(_ months: Set<Int>) {
        if months.count == 12 || months.isEmpty {
            monthMask = 0
            return
        }
        var mask: Int16 = 0
        for m in months {
            mask |= Int16(1) << (m - 1)
        }
        monthMask = mask
    }

    // MARK: - factory

    @discardableResult
    static func make(in context: NSManagedObjectContext) -> RecurrenceRule {
        let rule = RecurrenceRule(context: context)
        let now = Date()
        rule.id = UUID()
        rule.createdAt = now
        rule.updatedAt = now
        rule.itemFrequency = .daily
        rule.interval = 1
        return rule
    }

    // MARK: - 사용자용 요약 텍스트
    //
    // AddItemView·ItemRow 등 여러 곳에서 동일 규칙 요약을 노출하기 위한 공용 helper.
    // - daily: "매일" / "N일마다"
    // - weekly: "매주 화·목" (선택 요일 short symbol)
    // - monthly: 요일 ≤3 → "매월 1·15·말일" / "1·15·말일 of Jun·Dec", >3 → "5 days/month"
    //
    // formatMonthDay는 영어는 ordinal(1st·15th), 한국어는 정수(1일·15일)로 표기.

    /// 사용자에게 노출할 반복 패턴 요약. 비어있거나 미설정이면 "반복 없음"류 fallback.
    /// AddItemView.recurrenceSummaryText와 같은 규칙 — interval > 1이면 "N주마다/N개월마다/N년마다" 형식.
    func summaryText() -> String {
        let step = max(Int(interval), 1)
        switch itemFrequency {
        case .daily:
            if step <= 1 {
                return String(localized: "recurrence.summary.everyday")
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("recurrence.summary.every_n_days", comment: ""),
                step
            )

        case .weekly:
            let weekdays = selectedWeekdays.sorted()
            if weekdays.isEmpty {
                return String(localized: "recurrence.summary.weekly_unset")
            }
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            let symbols = formatter.shortWeekdaySymbols ?? []
            let names = weekdays.compactMap { idx -> String? in
                guard idx >= 1, idx <= symbols.count else { return nil }
                return symbols[idx - 1]
            }
            let daysStr = names.joined(separator: " · ")
            if step <= 1 {
                return String.localizedStringWithFormat(
                    NSLocalizedString("recurrence.summary.weekly_list", comment: ""),
                    daysStr)
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("recurrence.summary.weekly_list_interval", comment: ""),
                daysStr, step)

        case .monthly:
            // 조건지정(weekdayOrdinal) 우선 — "첫번째 월요일" / "마지막 날" 등.
            if let ordinal = weekdayOrdinalValue {
                let conditionText = Self.formatConditionSummary(
                    ordinal: ordinal, weekdayMask: weekdayMask)
                if step <= 1 {
                    return String.localizedStringWithFormat(
                        NSLocalizedString("recurrence.summary.monthly_all", comment: ""),
                        conditionText)
                }
                return String.localizedStringWithFormat(
                    NSLocalizedString("recurrence.summary.monthly_all_interval", comment: ""),
                    conditionText, step)
            }
            // 일자지정 + legacy 말일.
            let days = selectedDays.sorted()
            let hasLast = includesLastDay
            let totalCount = days.count + (hasLast ? 1 : 0)
            if totalCount == 0 {
                return String(localized: "recurrence.summary.monthly_unset")
            }
            let isList = totalCount <= 3
            let dayString: String = {
                guard isList else { return "" }
                var parts = days.map { Self.formatMonthDay($0) }
                if hasLast {
                    parts.append(String(localized: "recurrence.last_day_short"))
                }
                return parts.joined(separator: " · ")
            }()
            if step <= 1 {
                return isList
                    ? String.localizedStringWithFormat(
                        NSLocalizedString("recurrence.summary.monthly_all", comment: ""),
                        dayString)
                    : String.localizedStringWithFormat(
                        NSLocalizedString("recurrence.summary.monthly_all_count", comment: ""),
                        totalCount)
            }
            return isList
                ? String.localizedStringWithFormat(
                    NSLocalizedString("recurrence.summary.monthly_all_interval", comment: ""),
                    dayString, step)
                : String.localizedStringWithFormat(
                    NSLocalizedString("recurrence.summary.monthly_all_count_interval", comment: ""),
                    totalCount, step)

        case .yearly:
            let days = selectedDays.sorted()
            let hasLast = includesLastDay
            let totalDayCount = days.count + (hasLast ? 1 : 0)
            let dayString: String = {
                if totalDayCount == 0 || totalDayCount > 3 { return "" }
                var parts = days.map { Self.formatMonthDay($0) }
                if hasLast {
                    parts.append(String(localized: "recurrence.last_day_short"))
                }
                return parts.joined(separator: " · ")
            }()
            let months = selectedMonths
            let monthFormatter = DateFormatter()
            monthFormatter.locale = Locale.current
            let monthSymbols = monthFormatter.shortMonthSymbols ?? []
            let monthNames = months.sorted().compactMap { idx -> String? in
                guard idx >= 1, idx <= monthSymbols.count else { return nil }
                return monthSymbols[idx - 1]
            }
            let monthStr = monthNames.joined(separator: " · ")
            if dayString.isEmpty {
                if step <= 1 {
                    return String.localizedStringWithFormat(
                        NSLocalizedString("recurrence.summary.yearly_months_only", comment: ""),
                        monthStr)
                }
                return String.localizedStringWithFormat(
                    NSLocalizedString("recurrence.summary.yearly_months_only_interval", comment: ""),
                    monthStr, step)
            }
            if step <= 1 {
                return String.localizedStringWithFormat(
                    NSLocalizedString("recurrence.summary.yearly_specific", comment: ""),
                    dayString, monthStr)
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("recurrence.summary.yearly_specific_interval", comment: ""),
                dayString, monthStr, step)

        default:
            return String(localized: "recurrence.empty")
        }
    }

    /// 조건지정 요약 — "첫번째 월" / "마지막 날" 등.
    /// weekdayMask=0이면 "날" target, 비어있지 않으면 첫번째 set 비트의 weekday 짧은 라벨.
    static func formatConditionSummary(ordinal: Int, weekdayMask: Int16) -> String {
        let ordinalLabel = NSLocalizedString(conditionOrdinalKey(ordinal), comment: "")
        let targetLabel: String
        if weekdayMask == 0 {
            targetLabel = NSLocalizedString("recurrence.condition.target.day", comment: "")
        } else {
            // 단일 weekday 가정 — 가장 낮은 set 비트 사용.
            var weekday = 0
            for w in 1...7 where (weekdayMask & (Int16(1) << (w - 1))) != 0 {
                weekday = w; break
            }
            let f = DateFormatter()
            f.locale = Locale.current
            let symbols = f.veryShortWeekdaySymbols ?? []
            targetLabel = (weekday >= 1 && weekday <= symbols.count) ? symbols[weekday - 1] : ""
        }
        return "\(ordinalLabel) \(targetLabel)"
    }

    private static func conditionOrdinalKey(_ ordinal: Int) -> String {
        switch ordinal {
        case 1: return "recurrence.condition.ordinal.first"
        case 2: return "recurrence.condition.ordinal.second"
        case 3: return "recurrence.condition.ordinal.third"
        case 4: return "recurrence.condition.ordinal.fourth"
        case 5: return "recurrence.condition.ordinal.fifth"
        case lastOrdinalSentinel: return "recurrence.condition.ordinal.last"
        default: return ""
        }
    }

    /// 월별 일자 라벨 — 영어 ordinal, 그 외 정수 + "일".
    static func formatMonthDay(_ day: Int) -> String {
        let lang = Locale.preferredLanguages.first ?? ""
        let valueStr: String
        if lang.hasPrefix("en") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .ordinal
            formatter.locale = Locale.current
            valueStr = formatter.string(from: NSNumber(value: day)) ?? "\(day)"
        } else {
            valueStr = "\(day)"
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("recurrence.day_format", comment: ""),
            valueStr
        )
    }

    // MARK: - occurrence
    //
    // occurs / nextOccurrence는 모두 calendar date 의미의 Date(=UTC anchor)를 다루며,
    // 내부 비교/계산을 `Calendar.gmt`(UTC 고정)으로 통일한다.
    // 호출 측에서 넘기는 date, startDate, endDate는 반드시 UTC anchor Date여야 한다.
    // calendar 파라미터는 테스트 등 특수 경우에만 주입; 기본은 .gmt.

    /// 주어진 날짜가 이 규칙에 해당하는지. startDate는 anchor 필수.
    ///
    /// iCal RFC 5545 표준: DTSTART(=startDate)는 RRULE 패턴 매칭 여부와 무관하게
    /// recurrence set에 항상 포함된다. 따라서 day == startDay면 무조건 true 반환.
    /// 그 외 일자는 frequency별 rule 매칭으로 결정.
    func occurs(
        on date: Date,
        startDate: Date?,
        endDate: Date? = nil,
        calendar: Calendar = .gmt
    ) -> Bool {
        guard let start = startDate else { return false }
        let day = calendar.startOfDay(for: date)
        let startDay = calendar.startOfDay(for: start)
        if day < startDay { return false }
        if let end = endDate, day > calendar.startOfDay(for: end) { return false }
        // 설정한 시작일 자체는 항상 occurrence (iCal 표준).
        if day == startDay { return true }

        switch itemFrequency {
        case .daily:
            let days = calendar.dateComponents([.day], from: startDay, to: day).day ?? 0
            let step = max(Int(interval), 1)
            return days % step == 0

        case .weekly:
            // weekday: 1=일 … 7=토. UTC 캘린더에서 계산해 timezone 영향 차단.
            let weekday = calendar.component(.weekday, from: day)
            if !selectedWeekdays.contains(weekday) { return false }
            // interval(매 N주) — startDate가 속한 주와 day가 속한 주의 거리를 N으로 나눠떨어지는지 확인.
            // 주 alignment는 calendar.firstWeekday 기준 (한국=일요일, 유럽=월요일).
            let step = max(Int(interval), 1)
            if step <= 1 { return true }
            guard let weekStartOfStart = calendar.dateInterval(of: .weekOfYear, for: startDay)?.start,
                  let weekStartOfDay = calendar.dateInterval(of: .weekOfYear, for: day)?.start
            else { return false }
            let daysBetween = calendar.dateComponents([.day], from: weekStartOfStart, to: weekStartOfDay).day ?? 0
            let weeks = daysBetween / 7
            return weeks >= 0 && weeks % step == 0

        case .monthly:
            // 매월: 일자 매칭. interval 체크 후 → 조건지정(weekdayOrdinal) 우선, 그 다음 일자지정/말일.
            let monthNum = calendar.component(.month, from: day)
            if !selectedMonths.contains(monthNum) { return false }
            let step = max(Int(interval), 1)
            if step > 1 {
                let startYear = calendar.component(.year, from: startDay)
                let startMonth = calendar.component(.month, from: startDay)
                let dayYear = calendar.component(.year, from: day)
                let dayMonth = monthNum
                let monthsBetween = (dayYear - startYear) * 12 + (dayMonth - startMonth)
                if monthsBetween < 0 || monthsBetween % step != 0 { return false }
            }
            let dayNum = calendar.component(.day, from: day)
            // 조건지정: weekdayOrdinal 우선.
            if let ordinal = weekdayOrdinalValue {
                return matchesOrdinalCondition(
                    dayNum: dayNum, day: day, ordinal: ordinal, calendar: calendar)
            }
            // 일자지정 + 말일 (legacy).
            if selectedDays.contains(dayNum) { return true }
            if includesLastDay {
                let range = calendar.range(of: .day, in: .month, for: day)
                if let lastDay = range?.last, dayNum == lastDay { return true }
            }
            return false

        case .yearly:
            // 매년: (year - startYear) % interval == 0 + month 매칭 + day 매칭.
            // day는 selectedDays/includesLastDay 우선, 없으면 startDate.day 폴백.
            let step = max(Int(interval), 1)
            let yearStart = calendar.component(.year, from: startDay)
            let yearNow = calendar.component(.year, from: day)
            if yearNow < yearStart { return false }
            if (yearNow - yearStart) % step != 0 { return false }
            let monthNum = calendar.component(.month, from: day)
            if !selectedMonths.contains(monthNum) { return false }
            let dayNum = calendar.component(.day, from: day)
            if !selectedDays.isEmpty || includesLastDay {
                if selectedDays.contains(dayNum) { return true }
                if includesLastDay {
                    if let lastDay = calendar.range(of: .day, in: .month, for: day)?.last,
                       dayNum == lastDay { return true }
                }
                return false
            }
            return dayNum == calendar.component(.day, from: startDay)

        case .weekdays, .weekend, .weeklyCount:
            return false
        }
    }

    /// 조건지정 매칭 — 1~5 또는 마지막(-1) ordinal과 weekday/날 target 조합.
    /// weekdayMask != 0이면 "N번째 [요일]", == 0이면 "N번째 날" (일자 직접 매핑).
    private func matchesOrdinalCondition(
        dayNum: Int, day: Date, ordinal: Int, calendar: Calendar
    ) -> Bool {
        let lastDayOfMonth = calendar.range(of: .day, in: .month, for: day)?.last ?? 31
        if weekdayMask != 0 {
            // N번째 weekday 케이스. selectedWeekdays는 단일 weekday 가정.
            let weekday = calendar.component(.weekday, from: day)
            guard selectedWeekdays.contains(weekday) else { return false }
            // 해당 월 안에서 이 weekday의 몇 번째인지: ((dayNum - 1) / 7) + 1.
            let weekdayIndex = ((dayNum - 1) / 7) + 1
            if ordinal == Self.lastOrdinalSentinel {
                // 마지막: 다음 같은 요일(7일 후)이 월 경계를 넘으면 마지막.
                return dayNum + 7 > lastDayOfMonth
            }
            return weekdayIndex == ordinal
        }
        // "N번째 날" 케이스 — ordinal 그 자체가 일자.
        if ordinal == Self.lastOrdinalSentinel {
            return dayNum == lastDayOfMonth
        }
        return dayNum == ordinal
    }

    /// referenceDate 포함 이후 첫 occurrence. 없으면 nil.
    func nextOccurrence(
        after referenceDate: Date,
        startDate: Date?,
        endDate: Date? = nil,
        calendar: Calendar = .gmt
    ) -> Date? {
        let today = calendar.startOfDay(for: referenceDate)
        // 매년은 interval 최대 50년 등 day-by-day iterate가 비효율 — year skip 기반 별도 search.
        if itemFrequency == .yearly {
            return nextYearlyOccurrence(today: today, startDate: startDate, endDate: endDate, calendar: calendar)
        }
        var day = today
        // 최대 2년치 탐색.
        for _ in 0..<732 {
            if occurs(on: day, startDate: startDate, endDate: endDate, calendar: calendar) {
                return day
            }
            if let end = endDate, day > calendar.startOfDay(for: end) { return nil }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// Yearly 전용 next occurrence — interval에 맞춰 year skip 후 그 해 안에서 가장 이른 occurrence 탐색.
    /// today 포함 이후 first match return. 최대 100 사이클 탐색.
    /// iCal 표준: startDay 자체가 today 이후이면 항상 candidate에 포함.
    private func nextYearlyOccurrence(
        today: Date, startDate: Date?, endDate: Date?, calendar: Calendar
    ) -> Date? {
        guard let start = startDate else { return nil }
        let startDay = calendar.startOfDay(for: start)
        let endDayOrNil = endDate.map { calendar.startOfDay(for: $0) }
        // startDay 자체는 RRULE 매칭 여부 무관하게 첫 occurrence — today 이후면 우선 candidate.
        var startDayCandidate: Date? = nil
        if startDay >= today {
            if let endD = endDayOrNil, startDay > endD { /* endDate 지남 — skip */ }
            else { startDayCandidate = startDay }
        }
        let yearStart = calendar.component(.year, from: startDay)
        let step = max(Int(interval), 1)
        let currentYear = calendar.component(.year, from: today)
        // 시작년 ≥ max(currentYear, yearStart), step에 align.
        var year = max(currentYear, yearStart)
        while (year - yearStart) % step != 0 { year += 1 }
        let startDayOfMonth = calendar.component(.day, from: startDay)
        let useStartDayFallback = selectedDays.isEmpty && !includesLastDay
        for _ in 0..<100 {
            if let endD = endDayOrNil,
               year > calendar.component(.year, from: endD) { return nil }
            var bestInYear: Date? = nil
            for month in selectedMonths.sorted() {
                var monthComps = DateComponents()
                monthComps.year = year; monthComps.month = month; monthComps.day = 1
                guard let monthStart = calendar.date(from: monthComps),
                      let dayRange = calendar.range(of: .day, in: .month, for: monthStart)
                else { continue }
                let lastDayOfMonth = dayRange.last ?? 31
                var dayCandidates: Set<Int> = []
                if useStartDayFallback {
                    dayCandidates.insert(min(startDayOfMonth, lastDayOfMonth))
                } else {
                    for d in selectedDays where d <= lastDayOfMonth { dayCandidates.insert(d) }
                    if includesLastDay { dayCandidates.insert(lastDayOfMonth) }
                }
                for d in dayCandidates.sorted() {
                    var c = DateComponents(); c.year = year; c.month = month; c.day = d
                    guard let date = calendar.date(from: c) else { continue }
                    // calendar.date(from:)가 invalid day를 자동 rollover 할 수 있음 — 검증.
                    if calendar.component(.day, from: date) != d { continue }
                    if calendar.component(.month, from: date) != month { continue }
                    if date < today { continue }
                    if let endD = endDayOrNil, date > endD { continue }
                    if bestInYear == nil || date < bestInYear! { bestInYear = date }
                }
            }
            if let candidate = bestInYear {
                // startDay가 더 이른 occurrence면 우선.
                if let startC = startDayCandidate, startC < candidate { return startC }
                return candidate
            }
            year += step
        }
        // Rule 기반 candidate 없으면 startDay만이라도 반환.
        return startDayCandidate
    }
}
