import Foundation
import HealthKit

// MARK: - HealthKitService
//
// HealthKit 접근 wrapper — 활동 목표(steps/distance) 자동 측정용.
//
// Phase C 범위:
// - 걸음수(stepCount), 거리(distanceWalkingRunning) 2종 read-only
// - foreground fetch만 (scenePhase.active에서 호출)
// - 시간 window는 0:00~24:00 고정 (Phase B와 동일, 추후 startHour/dueHour 활용 확장)
// - background delivery는 v2 후속 phase
//
// 권한 흐름:
// 1. 사용자가 AddItemView에서 source = .steps/.distance 선택 → requestAuthorization 호출
// 2. 권한 거부 시 호출 측이 UI fallback (수동으로 전환 + alert)
// 3. 권한 상태는 HealthKit이 캐싱 — 동일 권한 재요청은 prompt 없이 즉시 반환
//
// 주의:
// - HealthKit은 시뮬레이터에서 거리는 0으로 반환할 수 있음 (real device 필요).
// - 권한 거부 후 사용자가 Settings에서 다시 켜도 앱이 다시 요청해야 함 → 매번 fetch 전 status 확인.

final class HealthKitService {

    static let shared = HealthKitService()

    let store = HKHealthStore()

    /// HealthKit 사용 가능 여부 (Mac에서는 false).
    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// 활성 observer 추적 — 중복 등록 방지. source별 1개.
    private var activeObservers: [ActivitySourceType: HKObserverQuery] = [:]

    // MARK: - 권한

    /// 주어진 source에 대한 read 권한 요청. 이미 결정된 경우 prompt 없이 즉시 반환.
    /// - Returns: 사용자가 허용했는지 확인 (실제 데이터 fetch 시도해 권한 상태 판단).
    /// HealthKit은 read 권한 status를 직접 노출하지 않음(privacy) — fetch 결과로 추론.
    func requestAuthorization(for source: ActivitySourceType) async -> Bool {
        guard isAvailable, let type = quantityType(for: source) else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: [type])
            return true  // 사용자 응답 자체 성공. 실제 허용 여부는 fetch 시 판단.
        } catch {
            return false
        }
    }

    // MARK: - 값 조회

    /// 주어진 source의 today(local 자정~다음 자정) 누적값. 권한 없으면 nil.
    /// - source: .steps, .distance만 지원 (.manual은 nil 반환)
    func fetchTodayValue(for source: ActivitySourceType) async -> Double? {
        await fetchValue(for: source, day: Date())
    }

    /// 임의 일자의 누적값 — start, end는 local 자정 기준. test/특정 occurrence용.
    func fetchValue(for source: ActivitySourceType, day: Date) async -> Double? {
        guard isAvailable, let type = quantityType(for: source) else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
        let unit = preferredUnit(for: source)

        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                let sum = stats?.sumQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: sum)
            }
            store.execute(query)
        }
    }

    // MARK: - Background Observer

    /// HKObserverQuery 등록 + enableBackgroundDelivery(.immediate).
    /// 같은 source 중복 등록은 skip (1 source = 1 observer, 그 안에서 모든 active 항목 일괄 처리).
    /// - handler: observer fire 시 호출. completion()을 반드시 호출해야 system이 다음 fire 보장.
    /// 호출 측에서 source별 활성 항목 fetch + RC update + 알림 + 위젯 reload + completion() 처리.
    func startBackgroundObservation(
        for source: ActivitySourceType,
        handler: @escaping (@escaping () -> Void) -> Void
    ) {
        guard isAvailable,
              source != .manual,
              activeObservers[source] == nil,
              let type = quantityType(for: source) else { return }

        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
            if let error {
                // 에러는 로그만 — observer 자체는 살아있음.
                print("[HK Observer] \(source) fire error: \(error.localizedDescription)")
                completion()
                return
            }
            handler(completion)
        }
        store.execute(query)
        activeObservers[source] = query

        // immediate frequency — 데이터 변화 즉시 시스템이 main app process 깨움.
        // Apple Watch 사용자에겐 실시간 fire, 그렇지 않으면 timestamp 도착에 따라 fire.
        store.enableBackgroundDelivery(for: type, frequency: .immediate) { success, error in
            if let error {
                print("[HK BG Delivery] \(source) enable error: \(error.localizedDescription)")
            } else if !success {
                print("[HK BG Delivery] \(source) enable failed (unknown)")
            }
        }
    }

    /// observer 해제 — 활성 활동 목표가 그 source에 없을 때 호출 (불필요한 wake 회피).
    /// 현 구현은 호출하지 않음 (한 번 등록 후 유지). 향후 source 빈 채로 launch 시 사용.
    func stopBackgroundObservation(for source: ActivitySourceType) {
        guard let query = activeObservers[source] else { return }
        store.stop(query)
        activeObservers[source] = nil
        if let type = quantityType(for: source) {
            store.disableBackgroundDelivery(for: type) { _, _ in }
        }
    }

    // MARK: - HKType 매핑

    /// ActivitySourceType → HKQuantityType. manual은 nil.
    private func quantityType(for source: ActivitySourceType) -> HKQuantityType? {
        switch source {
        case .manual:   return nil
        case .steps:    return HKQuantityType.quantityType(forIdentifier: .stepCount)
        case .distance: return HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)
        case .calories: return HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
        case .flights:  return HKQuantityType.quantityType(forIdentifier: .flightsClimbed)
        }
    }

    /// 표시 단위.
    /// - 걸음=count, 거리=meter, 칼로리=kcal, 계단=count(층수).
    /// - 사용자가 입력한 target 수치는 이 단위 기준으로 비교 (예: 거리 5000 = 5000m = 5km).
    private func preferredUnit(for source: ActivitySourceType) -> HKUnit {
        switch source {
        case .manual:   return .count()
        case .steps:    return .count()
        case .distance: return .meter()
        case .calories: return .kilocalorie()
        case .flights:  return .count()
        }
    }
}
