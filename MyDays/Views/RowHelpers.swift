import Foundation

// MARK: - Row 공용 free 함수
//
// ItemRow / MissionRow 양쪽에서 동일하게 쓰던 순수 함수 — Item·View 의존성 없는 utility는
// 별도 file로 분리해 어느 곳에서든 호출 가능하게 둠.

/// D-day 라벨 — "오늘" (days=0) / "D-3" (future) / "D+5" (past).
/// 호출 측에서 referenceDate 대비 일자 차이를 계산해 전달.
func formatDDay(_ days: Int) -> String {
    if days == 0 { return String(localized: "todo.list.today") }
    if days > 0  { return "D-\(days)" }
    return "D+\(-days)"
}
