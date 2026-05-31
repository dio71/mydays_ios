import Foundation
import CoreData

// MARK: - Item HealthKit foreground sync (Phase C-3)
//
// scenePhase==.active 시 RootView가 호출. auto source(.steps/.distance) 활동 항목의
// 오늘 occurrence valueRecorded를 HealthKit 누적값으로 set (absolute, increment 아님).
// target 도달 시 done=true. 1회성은 Item.status도 sync.
//
// 호출 조건: 오늘이 occurrence (반복 rule.occurs 또는 1회성 startDate==today)인 항목만.
// 권한 거부된 source는 fetchTodayValue가 nil 반환 → skip.
//
// 별도 파일에 둔 이유: HealthKitService는 main app target 전용 (widget extension에 포함 X).
// Item+Helpers.swift는 widget target에도 포함돼 있어 HK 호출이 들어가면 widget 빌드 실패.
// 이 파일은 main target에만 포함되도록 두어 분리.

extension Item {

    @MainActor
    static func syncHealthKitActivities(in context: NSManagedObjectContext) async {
        let service = HealthKitService.shared
        guard service.isAvailable else { return }

        // auto source(HealthKit 측정) 항목만 — manual은 사용자 입력이라 sync 대상 아님.
        let autoSources: [Int16] = [
            ActivitySourceType.steps.rawValue,
            ActivitySourceType.distance.rawValue,
            ActivitySourceType.calories.rawValue,
            ActivitySourceType.flights.rawValue,
        ]
        let request: NSFetchRequest<Item> = Item.fetchRequest()
        request.predicate = NSPredicate(
            format: "kind == %d AND status != %d AND activitySourceType IN %@",
            ItemKind.activity.rawValue,
            Status.deleted.rawValue,
            autoSources.map { NSNumber(value: $0) }
        )
        guard let items = try? context.fetch(request), !items.isEmpty else { return }

        let today = Date.todayCalendarAnchor

        for item in items {
            // 오늘이 active occurrence인지 판정.
            let isActiveToday: Bool
            if let rule = item.recurrenceRule {
                isActiveToday = rule.occurs(on: today, startDate: item.startDate, endDate: item.recurrenceEndDate)
            } else if let start = item.startDate,
                      Calendar.gmt.isDate(start, inSameDayAs: today),
                      item.itemStatus == .pending {
                isActiveToday = true
            } else {
                isActiveToday = false
            }
            guard isActiveToday else { continue }

            // HK fetch. 권한 거부 / 시뮬레이터 빈 데이터 시 nil → skip.
            guard let value = await service.fetchTodayValue(for: item.activitySource) else { continue }
            applyHealthKitValue(for: item, value: value, occurrenceDate: today, in: context)
        }

        if context.hasChanges {
            do { try context.save() } catch {
                assertionFailure("syncHealthKitActivities save failed: \(error)")
            }
        }
    }

    /// HK fetch 결과를 RC.valueRecorded에 absolute set. 누적 increment 아님 — HK는 day total.
    /// 같은 값이면 write skip (Core Data churn 회피).
    private static func applyHealthKitValue(
        for item: Item,
        value: Double,
        occurrenceDate: Date,
        in context: NSManagedObjectContext
    ) {
        let now = Date()
        let day = Calendar.gmt.startOfDay(for: occurrenceDate)
        let completions = (item.completions as? Set<RoutineCompletion>) ?? []
        let existing = completions.first { c in
            guard let d = c.date else { return false }
            return Calendar.gmt.isDate(d, inSameDayAs: day)
        }

        // 같은 값이면 skip — write 비용 + sync churn 회피. 0.5 단위 미만 차이는 무시.
        if let existing,
           let prev = existing.valueRecorded?.doubleValue,
           abs(prev - value) < 0.5 {
            return
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
        rc.valueRecorded = NSNumber(value: value)
        // target 도달 시 done flip. 이미 done이면 그대로 (초과 누적 허용).
        if let target = item.activityTargetValueInt, Int(value) >= target, !rc.done {
            rc.done = true
        }
        rc.completedAt = now
        // 1회성 활동의 Item.status sync — target 도달 시 done.
        if item.recurrenceRule == nil, rc.done {
            item.itemStatus = .done
            item.completedAt = now
        }
        item.updatedAt = now
    }
}
