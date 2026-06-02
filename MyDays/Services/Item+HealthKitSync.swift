import Foundation
import CoreData
import WidgetKit
import UserNotifications

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
            // HK sync로 RC.valueRecorded가 갱신됐으면 위젯도 즉시 reload — 사용자가 앱 열 때마다 진행률 최신화.
            // 백그라운드 자동 갱신(HKObserverQuery + enableBackgroundDelivery)은 별도 phase.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Background fire handler
    //
    // HKObserverQuery + enableBackgroundDelivery(.immediate)로 시스템이 main app process를 깨우면 호출.
    // 정책:
    //   - HK fetch 1회 (source 단위 cumulative)
    //   - 해당 source 활성 항목 loop:
    //     - prev = RC.valueRecorded ?? 0
    //     - reached = current >= target
    //     - 새로 도달(!prev done): RC.valueRecorded=current, done=true, 알림 fire, reload
    //     - 5% 이상 변화: RC.valueRecorded=current, reload
    //     - 그 외: skip (RC 갱신도 안 함, 다음 fire에서 누적 비교 정확도 유지)
    //   - reload는 1회만 (마지막에)
    //   - completion() 반드시 호출 (BG budget 보장)
    @MainActor
    static func handleHealthKitBackgroundFire(
        for source: ActivitySourceType,
        completion: @escaping () -> Void
    ) async {
        let service = HealthKitService.shared
        guard service.isAvailable, source != .manual else {
            completion()
            return
        }
        guard let current = await service.fetchTodayValue(for: source) else {
            completion()
            return
        }

        let context = PersistenceController.shared.viewContext
        let today: Date = .todayCalendarAnchor
        let now = Date()

        let request: NSFetchRequest<Item> = Item.fetchRequest()
        request.predicate = NSPredicate(
            format: "kind == %d AND activitySourceType == %d AND status != %d",
            ItemKind.activity.rawValue,
            source.rawValue,
            Status.deleted.rawValue
        )
        guard let items = try? context.fetch(request), !items.isEmpty else {
            completion()
            return
        }

        var shouldReload = false

        for item in items {
            // 오늘 active occurrence 판정 (foreground sync와 동일 로직).
            let active: Bool
            if let rule = item.recurrenceRule {
                active = rule.occurs(on: today, startDate: item.startDate, endDate: item.recurrenceEndDate)
            } else if let start = item.startDate,
                      Calendar.gmt.isDate(start, inSameDayAs: today),
                      item.itemStatus == .pending {
                active = true
            } else {
                active = false
            }
            guard active else { continue }

            // RC lookup
            let completions = (item.completions as? Set<RoutineCompletion>) ?? []
            let existing = completions.first { c in
                guard let d = c.date else { return false }
                return Calendar.gmt.isDate(d, inSameDayAs: today)
            }
            let prev = existing?.valueRecorded?.doubleValue ?? 0
            // 완료/포기된 RC는 그 시점의 snapshot 보존. 그 외는 item 현재 target 사용 (RC 갱신 시 sync됨).
            let effectiveTarget = existing.flatMap { ($0.done || $0.failed) ? $0.targetSnapshot?.doubleValue : nil }
                ?? item.activityTargetValueDouble ?? 0
            let wasDone = existing?.done ?? false
            let reached = effectiveTarget > 0 && current >= effectiveTarget
            let diff = abs(current - prev)
            let threshold = max(effectiveTarget * 0.05, 0.5)

            // 갱신 필요 판정.
            let needsUpdate: Bool
            if existing == nil {
                needsUpdate = true                    // 첫 fetch — RC 생성 + reload
            } else if reached && !wasDone {
                needsUpdate = true                    // 신규 target 달성
            } else if diff >= threshold {
                needsUpdate = true                    // 5% 이상 변화
            } else {
                needsUpdate = false                   // 미세 변화 — RC도 갱신 안 함 (다음 누적 비교 정확)
            }
            guard needsUpdate else { continue }

            let rc: RoutineCompletion
            if let existing {
                rc = existing
            } else {
                rc = RoutineCompletion(context: context)
                rc.id = UUID()
                rc.date = Calendar.gmt.startOfDay(for: today)
                rc.item = item
                rc.failed = false
            }
            rc.valueRecorded = NSNumber(value: current)
            // 미완료 RC는 targetSnapshot을 item 현재 값으로 sync. 완료/포기는 보존.
            if !rc.done && !rc.failed {
                rc.targetSnapshot = item.activityTargetValue
            }
            rc.completedAt = now

            if reached && !wasDone {
                rc.done = true
                // 1회성 활동 — Item.status도 done sync.
                if item.recurrenceRule == nil {
                    item.itemStatus = .done
                    item.completedAt = now
                }
                // 알림 fire — notifyOnGoalReached default ON (nil도 ON 해석).
                let notifyEnabled = (item.notifyOnGoalReached?.boolValue ?? true)
                if notifyEnabled {
                    fireGoalReachedAlert(for: item, occurrenceDate: today)
                }
            }

            item.updatedAt = now
            shouldReload = true
        }

        if context.hasChanges {
            do { try context.save() } catch {
                assertionFailure("[HK BG] save failed: \(error)")
            }
        }
        if shouldReload {
            WidgetCenter.shared.reloadAllTimelines()
        }
        completion()
    }

    /// 활동 목표 달성 알림 — 즉시 fire (trigger nil).
    /// ID: `activity_goal_reached:{itemID}:{occurrenceDate-epoch}` — 같은 occurrence 중복 fire 회피.
    /// 권한 거부 시 silent fail (UNUserNotificationCenter 자체 처리).
    private static func fireGoalReachedAlert(for item: Item, occurrenceDate: Date) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "activity_alert.goal_reached.title")
        content.body = String.localizedStringWithFormat(
            NSLocalizedString("activity_alert.goal_reached.body", comment: ""),
            item.title ?? ""
        )
        content.sound = .default
        let idBase = item.id?.uuidString ?? item.objectID.uriRepresentation().absoluteString
        let id = "activity_goal_reached:\(idBase):\(Int(occurrenceDate.timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[HK Alert] schedule failed: \(error)")
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
        // 미완료 RC는 targetSnapshot을 item 현재 값으로 sync. 완료/포기 RC는 보존.
        if !rc.done && !rc.failed {
            rc.targetSnapshot = item.activityTargetValue
        }
        // target 도달 시 done flip. 이미 done이면 그대로 (초과 누적 허용).
        // 판정은 effective target (snapshot 우선) 기준.
        let effectiveTarget = rc.targetSnapshot?.doubleValue ?? item.activityTargetValueDouble ?? 0
        if effectiveTarget > 0, value >= effectiveTarget, !rc.done {
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
