import Foundation
import CoreData

// MARK: - Item focus session accumulation
//
// 집중(focus) 세션 누적 helper. FocusSessionManager.stopSession에서 호출.
// 활동(activity) 모델 재활용:
// - activityTargetValueDouble = target 분
// - RC.valueRecorded = 누적 분
// - activityUnit = "분"
//
// 활동의 incrementActivityValue와 패턴 동일하나 Double 누적 (분 정밀도 필요)이라 별도 helper.
//
// 별도 파일 분리 이유 — main app target 전용. widget target에는 FocusSessionManager 미사용.

extension Item {

    /// 활동 측정용 Double accessor — focus 누적 분에 사용.
    /// (activityTargetValueInt는 정수만 — focus는 0.5분 같은 분수 가능하니 Double 별도)
    /// 호출 측에서 context.save() 책임.
    static func addFocusMinutes(
        _ minutes: Double,
        for item: Item,
        occurrenceDate: Date
    ) {
        guard minutes > 0, let context = item.managedObjectContext else { return }
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
        let prev = rc.valueRecorded?.doubleValue ?? 0
        let next = prev + minutes
        rc.valueRecorded = NSNumber(value: next)
        // target 도달 → done flip. overshoot 허용 — done 이후도 누적 add 가능.
        if let targetMinutes = item.activityTargetValueDouble, next >= targetMinutes, !rc.done {
            rc.done = true
        }
        // completedAt = 마지막 업데이트 instant — 정렬에서 최신 세션이 위로.
        rc.completedAt = now
        // 1회성 focus의 Item.status sync — target 도달 시 done.
        if item.recurrenceRule == nil, rc.done {
            item.itemStatus = .done
            item.completedAt = now
        }
        item.updatedAt = now
    }

    /// 집중 occurrence의 현재 누적 분.
    func focusCurrentMinutes(on occurrenceDate: Date) -> Double {
        guard let rc = routineRecord(on: occurrenceDate) else { return 0 }
        return rc.valueRecorded?.doubleValue ?? 0
    }
}
