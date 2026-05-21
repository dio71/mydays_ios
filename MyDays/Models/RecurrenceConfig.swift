import CoreData
import Foundation

struct RecurrenceConfig: Equatable {

    var frequency: Frequency
    var interval: Int
    var weekdays: Set<Int>           // Calendar.weekday 1=Sun ... 7=Sat
    var days: Set<Int>               // 1...31
    var includesLastDay: Bool
    var months: Set<Int>             // 1...12, empty/full = 모든 월

    static func makeDefault() -> RecurrenceConfig {
        RecurrenceConfig(
            frequency: .daily,
            interval: 1,
            weekdays: [],
            days: [],
            includesLastDay: false,
            months: Set(1...12)
        )
    }

    init(
        frequency: Frequency,
        interval: Int,
        weekdays: Set<Int>,
        days: Set<Int>,
        includesLastDay: Bool,
        months: Set<Int>
    ) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.days = days
        self.includesLastDay = includesLastDay
        self.months = months
    }

    init(from rule: RecurrenceRule) {
        self.frequency = rule.itemFrequency
        self.interval = max(Int(rule.interval), 1)
        self.weekdays = rule.selectedWeekdays
        self.days = rule.selectedDays
        self.includesLastDay = rule.includesLastDay
        self.months = rule.selectedMonths
    }

    func apply(to rule: RecurrenceRule) {
        rule.itemFrequency = frequency
        rule.interval = Int16(interval)
        rule.setSelectedWeekdays(weekdays)
        rule.setSelectedDays(days)
        rule.includesLastDay = includesLastDay
        rule.setSelectedMonths(months)
    }
}
