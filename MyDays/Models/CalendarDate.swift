import Foundation

// MARK: - Calendar Date 정책
//
// MyDays의 startDate / dueDate / RoutineCompletion.date 같은
// "달력 상의 날짜" 의미 필드는 timezone에 흔들리지 않도록
// **UTC 자정에 anchor**해서 저장한다.
//
// 예) 사용자가 "5/21" 입력 → 디바이스 timezone 무관하게
//     `2026-05-21 00:00:00 UTC` 로 저장.
//     이후 KST에서도, PDT에서도 동일한 calendar date로 해석됨.
//
// instant 의미 필드 (createdAt, updatedAt, completedAt, ItemEvent.timestamp,
// Reminder.fireDate)는 절대 시각이므로 이 anchor 정책의 대상이 아니다.
//
// 비교/연산은 `Calendar.gmt`, 표시는 `DateFormatter.timeZone = .gmt`
// 처럼 UTC 고정 환경에서만 한다. `Calendar.current`로 anchor된 Date를
// 다루면 timezone에 따라 라벨이 흔들리므로 사용 금지 (instant 필드 제외).

extension Calendar {

    /// UTC(GMT) 고정 그레고리안 캘린더.
    /// startDate/dueDate 등 calendar date 필드의 비교·연산 전용.
    /// firstWeekday는 사용자 로케일을 따라가게 두어 "주의 시작 요일" UI는 자연스럽게 유지.
    static let gmt: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        c.firstWeekday = Calendar.current.firstWeekday
        return c
    }()
}

extension Date {

    /// 사용자 local에서 읽어낸 년/월/일을 그대로 UTC 자정 instant로 변환.
    ///
    /// 사용처: SwiftUI DatePicker는 로컬 timezone 자정 Date를 반환한다.
    /// 이를 저장하기 전에 이 helper로 정규화해야 calendar date 의미가 보존된다.
    ///
    /// 예) KST에서 DatePicker로 5/21 선택 → self = 2026-05-21 00:00 KST
    ///     → comps = (2026, 5, 21)  ← timezone 정보 버림
    ///     → 결과 = 2026-05-21 00:00 UTC
    var calendarDateAnchor: Date {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: self)
        return Calendar.gmt.date(from: comps) ?? self
    }

    /// UTC anchor된 Date를 "같은 calendar date의 local 자정 instant"로 변환.
    ///
    /// 사용처: DatePickerSheet에 initialDate를 넘길 때.
    /// DatePicker는 local timezone으로 날짜를 표시하므로 UTC anchor를 그대로 넘기면
    /// 시차만큼 어긋난 날이 표시될 수 있다 (예: UTC 5/21 00:00 → PDT 5/20 17:00 → "5/20" 표시).
    /// 이 helper로 local 같은 날 자정으로 변환해 넘기면 UI에 의도한 날짜가 정확히 표시됨.
    var localCalendarSameDay: Date {
        let comps = Calendar.gmt.dateComponents([.year, .month, .day], from: self)
        return Calendar.current.date(from: comps) ?? self
    }

    /// 사용자 local 기준 "오늘"을 UTC anchor Date로 반환.
    ///
    /// daysUntil 계산, 만료 routine 체크 등에서 "지금이 어느 calendar date인가"의 기준점.
    /// `Calendar.gmt.startOfDay(for: Date())`는 UTC 오늘을 주는데, 이는
    /// 사용자가 체감하는 "오늘"과 다를 수 있다 (한국 새벽 2시면 UTC는 아직 어제).
    /// 그래서 local 기준 (y, m, d)를 뽑아 UTC anchor로 재구성.
    static var todayCalendarAnchor: Date {
        Date().calendarDateAnchor
    }
}
