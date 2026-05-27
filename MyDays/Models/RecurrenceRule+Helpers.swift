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
    func summaryText() -> String {
        switch itemFrequency {
        case .daily:
            if interval <= 1 {
                return String(localized: "recurrence.summary.everyday")
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("recurrence.summary.every_n_days", comment: ""),
                Int(interval)
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
            return String.localizedStringWithFormat(
                NSLocalizedString("recurrence.summary.weekly_list", comment: ""),
                daysStr
            )

        case .monthly:
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

            let months = selectedMonths
            let isAllMonths = months.isEmpty || months.count >= 12

            if isAllMonths {
                return isList
                    ? String.localizedStringWithFormat(
                        NSLocalizedString("recurrence.summary.monthly_all", comment: ""),
                        dayString)
                    : String.localizedStringWithFormat(
                        NSLocalizedString("recurrence.summary.monthly_all_count", comment: ""),
                        totalCount)
            }

            let monthFormatter = DateFormatter()
            monthFormatter.locale = Locale.current
            let monthSymbols = monthFormatter.shortMonthSymbols ?? []
            let monthNames = months.sorted().compactMap { idx -> String? in
                guard idx >= 1, idx <= monthSymbols.count else { return nil }
                return monthSymbols[idx - 1]
            }
            let monthStr = monthNames.joined(separator: " · ")
            return isList
                ? String.localizedStringWithFormat(
                    NSLocalizedString("recurrence.summary.monthly_specific", comment: ""),
                    dayString, monthStr)
                : String.localizedStringWithFormat(
                    NSLocalizedString("recurrence.summary.monthly_specific_count", comment: ""),
                    totalCount, monthStr)

        default:
            return String(localized: "recurrence.empty")
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

        switch itemFrequency {
        case .daily:
            let days = calendar.dateComponents([.day], from: startDay, to: day).day ?? 0
            let step = max(Int(interval), 1)
            return days % step == 0

        case .weekly:
            // weekday: 1=일 … 7=토. UTC 캘린더에서 계산해 timezone 영향 차단.
            let weekday = calendar.component(.weekday, from: day)
            return selectedWeekdays.contains(weekday)

        case .monthly:
            let dayNum = calendar.component(.day, from: day)
            let monthNum = calendar.component(.month, from: day)
            if !selectedMonths.contains(monthNum) { return false }
            if selectedDays.contains(dayNum) { return true }
            if includesLastDay {
                let range = calendar.range(of: .day, in: .month, for: day)
                if let lastDay = range?.last, dayNum == lastDay { return true }
            }
            return false

        case .weekdays, .weekend, .weeklyCount:
            return false
        }
    }

    /// referenceDate 포함 이후 첫 occurrence. 없으면 nil.
    func nextOccurrence(
        after referenceDate: Date,
        startDate: Date?,
        endDate: Date? = nil,
        calendar: Calendar = .gmt
    ) -> Date? {
        let today = calendar.startOfDay(for: referenceDate)
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
}
