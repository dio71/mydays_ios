import CoreData
import SwiftUI

// MARK: - YearGridView
//
// 단일 항목 (per-item)의 1년치 활동 기록 visualization. GitHub contribution graph 패턴.
//
// 레이아웃:
// - 7 rows (요일, 시스템 firstWeekday 시작) × 최대 53 columns (주)
// - 왼쪽→오른쪽 = 시간 진행 (1월 1주차 → 12월 마지막 주)
// - 각 cell = MonthGridView의 dot rendering과 동일 정책:
//   · pending: stroke
//   · completed: filled solid
//   · cancelled (과거 미달성 / 명시 포기): filled opacity 0.2
//   · none (활성 occurrence 없음): empty
// - 모양: 목표=원, 할일=사각 (MonthGridView dot 정책 유지)
//
// 사용처: ActivityHistoryView (per-item) toolbar M/Y 토글로 MonthGridView와 교체.
//
// 네비게이션:
// - 가로 swipe → ±1년 (onShiftYear callback)
// - 일자 선택은 비활성 (단순 조망)
//
// 퍼포먼스:
// - 총 cell 수 약 7×53=371. 각 cell 마다 cellState 계산.
// - RC FetchRequest로 mutation observe (MonthGridView와 동일 패턴).

struct YearGridView: View {

    @ObservedObject var item: Item
    /// 표시 연도 (e.g., 2026). UTC 기준.
    let year: Int
    /// 직전 navigation 방향 — 슬라이드 transition 방향.
    let forward: Bool
    /// 가로 swipe로 ±1년 shift callback.
    let onShiftYear: (Int) -> Void

    @FetchRequest(
        sortDescriptors: [SortDescriptor(\RoutineCompletion.completedAt, order: .reverse)],
        animation: .default
    )
    private var allCompletions: FetchedResults<RoutineCompletion>

    // MARK: - body

    var body: some View {
        // RC FetchRequest 의존성 강제 — RC mutate 시 body 재실행 보장.
        let _ = allCompletions.count
        let insertionEdge: Edge = forward ? .trailing : .leading
        let removalEdge: Edge = forward ? .leading : .trailing
        let weeks = weekColumns()

        ZStack {
            GeometryReader { proxy in
                // available width - (column gaps). column gap 1pt × (count-1).
                let gap: CGFloat = 1.5
                let totalGap = gap * CGFloat(max(0, weeks.count - 1))
                let cellSize = max(3, (proxy.size.width - totalGap) / CGFloat(weeks.count))

                HStack(alignment: .top, spacing: gap) {
                    ForEach(0..<weeks.count, id: \.self) { weekIdx in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { rowIdx in
                                cell(day: weeks[weekIdx][rowIdx], size: cellSize)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: gridHeight)
            .id(year)
            .transition(.asymmetric(
                insertion: .move(edge: insertionEdge),
                removal: .move(edge: removalEdge)
            ))
        }
        .clipped()
        .animation(.easeInOut(duration: 0.22), value: year)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .highPriorityGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    let h = value.translation.width
                    let v = value.translation.height
                    guard abs(h) > 60, abs(h) > abs(v) * 2 else { return }
                    onShiftYear(h > 0 ? -1 : 1)
                }
        )
    }

    /// 7 row × cellSize + 6 × gap(1.5pt). cellSize는 width / 53 로 동적이라
    /// 화면 폭이 클수록 grid도 커짐. 폰 360pt → ~44pt, sheet 400pt → ~50pt, iPad → ~70pt+.
    /// `.clipped()`로 outer ZStack을 자르니 부족하면 마지막 row가 잘림. 안전 마진 두고 70pt.
    private var gridHeight: CGFloat { 70 }

    // MARK: - 주(컬럼) 계산

    /// 표시 연도의 모든 주를 [[Date]]로. 각 주는 firstWeekday 기준 7일.
    /// 1월 1일이 firstWeekday가 아니면 이전 해 일자가 첫 주 앞에 포함. 12월 31일도 마찬가지.
    /// 이런 out-of-year 일자는 cell에서 empty로 렌더 (isInYear 검사).
    private func weekColumns() -> [[Date]] {
        // 1월 1일 / 12월 31일 (UTC)
        var comps = DateComponents()
        comps.year = year
        comps.month = 1
        comps.day = 1
        guard let janFirst = Calendar.gmt.date(from: comps) else { return [] }
        comps.month = 12
        comps.day = 31
        guard let decLast = Calendar.gmt.date(from: comps) else { return [] }

        // local firstWeekday 기준으로 grid 시작·끝 주 결정.
        let firstWeekday = Calendar.current.firstWeekday  // 1=Sun, 2=Mon ...
        let janWeekday = Calendar.gmt.component(.weekday, from: janFirst)
        let daysBefore = (janWeekday - firstWeekday + 7) % 7
        guard let gridStart = Calendar.gmt.date(byAdding: .day, value: -daysBefore, to: janFirst) else { return [] }

        let decWeekday = Calendar.gmt.component(.weekday, from: decLast)
        let daysAfter = (firstWeekday + 6 - decWeekday + 7) % 7
        guard let gridEnd = Calendar.gmt.date(byAdding: .day, value: daysAfter, to: decLast) else { return [] }

        let totalDays = (Calendar.gmt.dateComponents([.day], from: gridStart, to: gridEnd).day ?? 0) + 1
        var allDays: [Date] = []
        allDays.reserveCapacity(totalDays)
        for i in 0..<totalDays {
            if let d = Calendar.gmt.date(byAdding: .day, value: i, to: gridStart) {
                allDays.append(d)
            }
        }
        // 7개씩 분할.
        var weeks: [[Date]] = []
        weeks.reserveCapacity((allDays.count + 6) / 7)
        for i in stride(from: 0, to: allDays.count, by: 7) {
            let end = min(i + 7, allDays.count)
            weeks.append(Array(allDays[i..<end]))
        }
        return weeks
    }

    // MARK: - cell rendering

    @ViewBuilder
    private func cell(day: Date, size: CGFloat) -> some View {
        let state = cellState(day: day)
        let color = itemColor
        let isTodo = item.itemKind == .todo
        // Todo는 살짝 round된 사각, 목표는 원.
        // strokeBorder는 InsettableShape 한정 (Circle/RoundedRectangle은 conform) — fill과 동일 outer size 보장.
        // AnyShape로 erase하면 InsettableShape 제약이 풀려 strokeBorder 사용 불가 → 각 case에 inline 분기.
        Group {
            switch state {
            case .none:
                // 빈 날짜는 항목 색상 무관 회색 — 활성 일자(pending/completed/cancelled)와 시각 구분.
                if isTodo {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(Color.secondary.opacity(0.05))
                } else {
                    Circle().fill(Color.secondary.opacity(0.05))
                }
            case .pending:
                if isTodo {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous).strokeBorder(color, lineWidth: 1)
                } else {
                    Circle().strokeBorder(color, lineWidth: 1)
                }
            case .completed:
                if isTodo {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(color)
                } else {
                    Circle().fill(color)
                }
            case .cancelled:
                if isTodo {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(color).opacity(0.2)
                } else {
                    Circle().fill(color).opacity(0.2)
                }
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - cell state

    private enum CellState { case none, pending, completed, cancelled }

    /// 그 day의 cell 상태. MonthGridView.indicatorState 정책과 통일.
    /// - none: 활성 occurrence 없음 / 표시 연도 외
    /// - pending: 오늘/미래 활성 occurrence + 미완료
    /// - completed: RC.done OR target 도달 OR Item.status=done
    /// - cancelled: RC.failed OR Item.status=failed OR 과거 활성 + 미달성
    private func cellState(day: Date) -> CellState {
        guard isInYear(day) else { return .none }
        // 목표 미래일자: 미노출 — MonthGridView pickedRingState 정책과 통일 (사용자 정책: 목표는 과거+오늘만 표시).
        if item.itemKind.isGoal && day > .todayCalendarAnchor { return .none }

        let isActive: Bool
        if let rule = item.recurrenceRule {
            isActive = rule.occurs(on: day, startDate: item.startDate, endDate: item.recurrenceEndDate)
        } else if let s = item.startDate {
            isActive = Calendar.gmt.isDate(s, inSameDayAs: day)
        } else {
            isActive = false
        }
        guard isActive else { return .none }

        let kind = item.itemKind
        let isPast = day < .todayCalendarAnchor

        // 명시적 포기 우선.
        let isFailed: Bool = {
            if item.recurrenceRule != nil {
                return item.routineRecord(on: day)?.failed == true
            }
            return item.itemStatus == .failed
        }()
        if isFailed { return .cancelled }

        // 완료 — 활동/집중은 valueRecorded vs target 직접 검사 (done flag stale 대비).
        let isDone: Bool = {
            if let rc = item.routineRecord(on: day) {
                if rc.done { return true }
                if kind == .activity || kind == .focus {
                    let val = rc.valueRecorded?.doubleValue ?? 0
                    let target = rc.targetSnapshot?.doubleValue ?? item.activityTargetValueDouble ?? 0
                    if target > 0 && val >= target { return true }
                }
            }
            if item.recurrenceRule == nil, item.itemStatus == .done { return true }
            return false
        }()
        if isDone { return .completed }

        // 과거 + 미달성 → cancelled (활동/집중 미완료 정책 + 다른 type도 일관 처리).
        if isPast { return .cancelled }

        return .pending
    }

    private func isInYear(_ day: Date) -> Bool {
        Calendar.gmt.component(.year, from: day) == year
    }

    /// dot 색 — 목표는 iconColorHex, Todo는 category color. fallback secondary.
    private var itemColor: Color {
        if item.itemKind == .todo {
            guard let raw = item.category?.colorHex, let cc = CategoryColor(rawValue: raw) else {
                return Color.secondary
            }
            return cc.color
        }
        guard let raw = item.iconColorHex, let cc = CategoryColor(rawValue: raw) else {
            return Color.secondary
        }
        return cc.color
    }
}
