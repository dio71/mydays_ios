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
        rule.id = UUID()
        rule.itemFrequency = .daily
        rule.interval = 1
        return rule
    }

    // MARK: - occurrence

    /// 주어진 날짜가 이 규칙에 해당하는지. startDate는 anchor 필수.
    func occurs(
        on date: Date,
        startDate: Date?,
        endDate: Date? = nil,
        calendar: Calendar = .current
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
        calendar: Calendar = .current
    ) -> Date? {
        let today = calendar.startOfDay(for: referenceDate)
        var day = today
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
