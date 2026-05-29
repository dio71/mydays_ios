import Foundation

// MARK: - AlertOffset
//
// 알림 offset(분) 선택지 + 라벨 포맷. AddItemView / CategoryEditSheet 등에서 공유.
// 시각 있는 항목: anchor instant 기준 ±N분 (정시·10·30·60분 전).
// 시각 미설정 Todo: anchor=startDate 0시 기준. +540=당일 9am, +840=당일 2pm,
//                  +1140=당일 7pm, -180=1일전 9pm, -1620=2일전 9pm.

enum AlertOffset {
    /// 시각 있는 항목(NTD / Todo hasTime=true)용 offset 옵션.
    static let withTimeOptions: [Int] = [0, -10, -30, -60]
    /// 시각 미설정 Todo(hasTime=false)용 offset 옵션.
    static let noTimeOptions: [Int] = [540, 840, 1140, -180, -1620]

    /// offset(분) → 사용자에게 보일 라벨. 시각 미설정 매핑(540 등)을 우선 적용한 뒤
    /// 시각 있는 항목(0/-10/-30/-60)을 처리.
    static func label(for offset: Int) -> String {
        switch offset {
        case 540:   return String(localized: "alert.offset.same_day_9am")
        case 840:   return String(localized: "alert.offset.same_day_2pm")
        case 1140:  return String(localized: "alert.offset.same_day_7pm")
        case -180:  return String(localized: "alert.offset.day_before_9pm")
        case -1620: return String(localized: "alert.offset.two_days_before_9pm")
        default: break
        }
        if offset == 0 {
            return String(localized: "alert.offset.exact")
        }
        if offset == -60 {
            return String(localized: "alert.offset.hour_before")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("alert.offset.minutes_before_format", comment: ""),
            abs(offset)
        )
    }
}
