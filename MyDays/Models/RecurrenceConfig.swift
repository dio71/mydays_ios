import CoreData
import Foundation

struct RecurrenceConfig: Equatable {

    var frequency: Frequency
    var interval: Int
    var weekdays: Set<Int>           // Calendar.weekday 1=Sun ... 7=Sat
    var days: Set<Int>               // 1...31
    var includesLastDay: Bool
    var months: Set<Int>             // 1...12, empty/full = 모든 월
    /// 조건지정 ordinal — 1~5(첫~다섯번째), -1(마지막), nil(조건지정 미사용 = 일자지정).
    /// `weekdays`가 비어있지 않으면 "N번째 [요일]", 비어있으면 "N번째 날" (직접 일자 매핑).
    var weekdayOrdinal: Int?

    static func makeDefault() -> RecurrenceConfig {
        RecurrenceConfig(
            frequency: .daily,
            interval: 1,
            weekdays: [],
            days: [],
            includesLastDay: false,
            months: Set(1...12),
            weekdayOrdinal: nil
        )
    }

    init(
        frequency: Frequency,
        interval: Int,
        weekdays: Set<Int>,
        days: Set<Int>,
        includesLastDay: Bool,
        months: Set<Int>,
        weekdayOrdinal: Int? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.days = days
        self.includesLastDay = includesLastDay
        self.months = months
        self.weekdayOrdinal = weekdayOrdinal
    }

    init(from rule: RecurrenceRule) {
        self.interval = max(Int(rule.interval), 1)
        self.weekdays = rule.selectedWeekdays
        self.days = rule.selectedDays
        self.includesLastDay = rule.includesLastDay
        self.months = rule.selectedMonths
        self.weekdayOrdinal = rule.weekdayOrdinalValue
        // 자동 감지: 기존 데이터의 "매월 + 특정 monthMask" 는 의미상 매년 — yearly UI로 노출.
        // (monthMask=0은 모든 월 → 진짜 매월, monthMask≠0은 특정 월 = 매년 패턴)
        // 저장 시 .yearly로 기록되므로 점진적 마이그.
        if rule.itemFrequency == .monthly && rule.monthMask != 0 {
            self.frequency = .yearly
        } else {
            self.frequency = rule.itemFrequency
        }
    }

    func apply(to rule: RecurrenceRule) {
        rule.itemFrequency = frequency
        rule.interval = Int16(interval)
        rule.setSelectedWeekdays(weekdays)
        rule.setSelectedDays(days)
        rule.includesLastDay = includesLastDay
        rule.setSelectedMonths(months)
        rule.weekdayOrdinalValue = weekdayOrdinal
        rule.updatedAt = Date()
    }
}
