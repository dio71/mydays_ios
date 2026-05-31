import Foundation
import CoreData
import SwiftUI
import Combine

// MARK: - FocusSessionManager
//
// 전역 active focus 추적 + 세션 누적 처리.
//
// 정책:
// - **single-active**: 동시 1개만. 새 세션 시작 시 기존 active 자동 중단.
// - **wall-clock 기반**: 시작 instant만 저장, 종료 시 elapsed = now - start 계산.
// - **min 10분**: 종료 시 elapsed >= 10분이면 RoutineCompletion.valueRecorded에 누적, 미만이면 폐기.
// - **target**: Item.activityTargetValueDouble = target 분 (Double). RC.valueRecorded += 분.
// - **target 도달**: overshoot 허용. 사용자가 명시적 stop 누를 때까지 누적 계속.
//
// session start 시각은 RAM only — 앱 종료 시 잃음. foreground 종료가 곧 세션 종료라 무관.
//
// observer 패턴: @Published activeItemID 로 UI(특히 FocusSessionView dismiss)가 자동 갱신.

@MainActor
final class FocusSessionManager: ObservableObject {

    static let shared = FocusSessionManager()

    /// 현재 active focus item의 objectID (있으면). nil이면 idle.
    @Published private(set) var activeItem: Item?
    /// 현재 session 시작 instant. activeItem과 함께 set/clear.
    @Published private(set) var sessionStartedAt: Date?

    /// 누적되지 않는 최소 세션 시간 (분). MVP hardcode.
    static let minSessionMinutes: Double = 10

    private init() {}

    /// 현재 active 여부 — UI에서 ▶ 버튼 disable 등에 사용.
    var isSessionActive: Bool { activeItem != nil }

    /// session 시작. 기존 active 있으면 자동 stop(누적 적용).
    /// occurrenceDate는 세션 종료 시 RC를 어느 일자에 적재할지 결정 (반복은 occurrence start, 1회성은 item.startDate).
    func startSession(item: Item, occurrenceDate: Date) {
        if activeItem != nil {
            // 기존 active 자동 중단 — 사용자가 새 session 시작 의도 우선.
            stopSession()
        }
        activeItem = item
        sessionStartedAt = Date()
    }

    /// session 정지 — elapsed 계산해 RC에 누적 add 여부 결정.
    /// 누적 조건:
    /// - elapsed ≥ 10분: 항상 누적
    /// - elapsed < 10분 + 이 세션으로 **target 도달**: 누적 인정 (final stretch)
    /// - elapsed < 10분 + target 미도달: 폐기 (게이밍 방지)
    /// occurrenceDate는 startSession 시점의 값을 사용 (RAM 보존).
    /// 호출 지점: 사용자 정지 / scenePhase=.background / motion 임계치 / target 자동 종료.
    @discardableResult
    func stopSession() -> SessionResult {
        guard let item = activeItem, let start = sessionStartedAt else {
            return .noActive
        }
        let elapsed = Date().timeIntervalSince(start)
        let elapsedMinutes = elapsed / 60.0
        defer {
            activeItem = nil
            sessionStartedAt = nil
        }
        let occDate = focusOccurrenceDate(for: item, at: start)
        // target 도달 시 길이 무관 인정 — final stretch (예: 누적 55/60에서 5분 세션) 케이스 커버.
        let storedMinutes = item.focusCurrentMinutes(on: occDate)
        let projectedTotal = storedMinutes + elapsedMinutes
        let willReachTarget = item.activityTargetValueDouble.map { projectedTotal >= $0 } ?? false
        guard elapsedMinutes >= Self.minSessionMinutes || willReachTarget else {
            return .discardedShort(elapsedMinutes: elapsedMinutes)
        }
        Item.addFocusMinutes(elapsedMinutes, for: item, occurrenceDate: occDate)
        if let ctx = item.managedObjectContext {
            do { try ctx.save() } catch {
                assertionFailure("FocusSession save failed: \(error)")
            }
        }
        return .accumulated(minutes: elapsedMinutes)
    }

    /// session 종료 결과 — 호출자가 UI 안내 등에 사용 가능.
    enum SessionResult {
        case noActive
        case discardedShort(elapsedMinutes: Double)
        case accumulated(minutes: Double)
    }

    /// session 시작 시점 기준 occurrence date.
    /// - 반복: 시작 instant 시점에 active occurrence가 있으면 그 start, 없으면 referenceOccurrence (다음 future).
    /// - 1회성: item.startDate (또는 오늘 anchor fallback).
    private func focusOccurrenceDate(for item: Item, at sessionStart: Date) -> Date {
        let viewDate = sessionStart.calendarDateAnchor
        if item.recurrenceRule != nil {
            if let occ = item.occurrenceStartDate(on: viewDate) {
                return occ
            }
            return item.referenceOccurrenceStartDate(viewDate: viewDate) ?? viewDate
        }
        return item.startDate ?? viewDate
    }
}
