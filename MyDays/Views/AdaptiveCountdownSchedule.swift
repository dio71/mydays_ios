import SwiftUI

/// 적용 target instant까지 남은 시간에 따라 갱신 주기 가변 — NTD 카운트다운 / Todo 시각 전환 공용.
///
/// 규칙:
///   - 1분 미만: 1초마다 (초 단위 정밀)
///   - 1시간 미만: 30초마다 (분 단위 부드럽게)
///   - 그 외: 60초마다 (배터리 saving)
///   - target nil(없음/지남): 60s 기본
///
/// target은 closure로 받아 매 tick마다 동적으로 재계산 — state 전환(scheduled→inProgress 등)
/// 시점에 즉시 새 target으로 interval 조정됨.
struct AdaptiveCountdownSchedule: TimelineSchedule {
    let targetProvider: (Date) -> Date?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var current = startDate
        let provider = self.targetProvider
        return AnyIterator {
            let interval: TimeInterval
            if let t = provider(current) {
                let remaining = t.timeIntervalSince(current)
                if remaining > 0 && remaining < 60 {
                    interval = 1
                } else if remaining > 0 && remaining < 3600 {
                    interval = 30
                } else {
                    interval = 60
                }
            } else {
                interval = 60
            }
            current = current.addingTimeInterval(interval)
            return current
        }
    }
}
