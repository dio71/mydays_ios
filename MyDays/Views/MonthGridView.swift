import CoreData
import SwiftUI

// MARK: - MonthGridView
//
// TodayView Month 모드 상단에 표시하는 월간 7×6 grid.
// - 요일 헤더(1행) + 일자 cell(6행 = 42 cells, 인접 월 일부 포함)
// - 일자 cell 탭 → onSelectDate(date) (M 모드 유지, TodayList만 갱신)
// - 가로 swipe → onShiftMonth(±1) → 부모가 ±1개월 navigate
// - 주 시작점: `Calendar.current.firstWeekday` (한국=일요일, 유럽=월요일 자동)
// - 날짜 표시·비교는 UTC anchor. firstWeekday / 월 boundary는 local Calendar로 계산.
//
// Phase 3 (NTD 히스토리 등) 재활용 대비:
// cell 구조 단순(date + 선택/오늘 강조)으로 유지. 추후 cellDecorator prop으로 indicator 주입 예정.

struct MonthGridView: View {

    /// 현재 선택된 일자 (UTC anchor). grid 표시 월의 anchor.
    let selectedDate: Date

    /// 직전 navigation 방향 — 슬라이드 transition 방향 계산용.
    let forward: Bool

    /// 일자 cell 탭 callback — 부모에서 displayedDate 변경.
    let onSelectDate: (Date) -> Void

    /// 가로 swipe로 ±1개월 shift callback.
    let onShiftMonth: (Int) -> Void

    /// 모든 active 항목 — Someday 제외, 삭제(status=2) 제외. cell 인디케이터(dot) 계산용.
    /// 일자별로 어떤 항목이 cover하는지 매 render마다 계산. 100여개 항목 × 42 cells 정도면 무시 가능 비용.
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Item.startDate)],
        predicate: NSPredicate(format: "status != 2 AND isSomeday == NO"),
        animation: .default
    )
    private var allItems: FetchedResults<Item>

    var body: some View {
        // TodayView/WeekStripView와 동일한 transition 패턴.
        let insertionEdge: Edge = forward ? .trailing : .leading
        let removalEdge: Edge = forward ? .leading : .trailing

        VStack(spacing: 4) {
            // 요일 헤더 — firstWeekday 기준으로 회전된 short symbols.
            HStack(spacing: 0) {
                ForEach(Self.weekdaySymbols(), id: \.self) { sym in
                    Text(verbatim: sym)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            // 일자 grid — 월 단위 transition.
            // LazyVGrid 대신 VStack of HStacks(spacing: 0)로 직접 배치 — cell 사이 간격을 정확히 0으로
            // 제어해야 다일 항목 bar가 인접 cell 경계를 넘어 시각적으로 연속됨.
            // (LazyVGrid는 column flexible 안에서 cell content를 cell width까지 늘리지 않는 quirk가 있음.)
            ZStack {
                VStack(spacing: 4) {
                    ForEach(0..<weekCount, id: \.self) { weekIdx in
                        // alignment: .top — cell 마다 content 높이(dot 수 등)가 달라도 위쪽 기준 정렬해
                        // 같은 slot의 bar가 같은 y 위치에 와서 연속 line으로 보이게 함.
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<7, id: \.self) { dayIdx in
                                let day = days[weekIdx * 7 + dayIdx]
                                cell(for: day)
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        onSelectDate(day)
                                    }
                            }
                        }
                    }
                }
                .id(monthAnchor)
                .transition(.asymmetric(
                    insertion: .move(edge: insertionEdge),
                    removal: .move(edge: removalEdge)
                ))
            }
            .clipped()
            .animation(.easeInOut(duration: 0.22), value: monthAnchor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    let h = value.translation.width
                    let v = value.translation.height
                    guard abs(h) > 60, abs(h) > abs(v) * 2 else { return }
                    // 오른쪽 swipe → 이전 월, 왼쪽 swipe → 다음 월 (week strip / 본문 swipe와 방향 일치).
                    onShiftMonth(h > 0 ? -1 : 1)
                }
        )
    }

    // MARK: - 날짜 계산

    /// 화면에 표시할 일자들 (weekCount × 7일). 월 첫주 시작 ~ 월 마지막주 끝 사이.
    /// 대부분 5주, 31일 월이 금/토 시작이면 6주, 28일 2월이 first weekday 시작이면 4주.
    private var days: [Date] {
        guard let start = gridStart, let end = gridEnd else { return [] }
        let total = (Calendar.gmt.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return (0..<total).compactMap {
            Calendar.gmt.date(byAdding: .day, value: $0, to: start)
        }
    }

    /// 표시할 week 수 — days.count / 7. 4~6 범위.
    private var weekCount: Int { max(1, days.count / 7) }

    /// grid의 첫 칸(좌상단) — selectedDate가 속한 월의 1일이 포함된 주의 시작 (firstWeekday 기준).
    private var gridStart: Date? {
        let cal = Calendar.current
        let local = selectedDate.localCalendarSameDay
        let comps = cal.dateComponents([.year, .month], from: local)
        guard let monthStart = cal.date(from: comps),
              let weekInterval = cal.dateInterval(of: .weekOfYear, for: monthStart)
        else { return nil }
        return weekInterval.start.calendarDateAnchor
    }

    /// grid의 마지막 칸(우하단) — selectedDate가 속한 월의 마지막 일이 포함된 주의 끝.
    private var gridEnd: Date? {
        let cal = Calendar.current
        let local = selectedDate.localCalendarSameDay
        guard let monthInterval = cal.dateInterval(of: .month, for: local),
              let lastDay = cal.date(byAdding: .day, value: -1, to: monthInterval.end),
              let weekInterval = cal.dateInterval(of: .weekOfYear, for: lastDay),
              let lastWeekDay = cal.date(byAdding: .day, value: -1, to: weekInterval.end)
        else { return nil }
        return lastWeekDay.calendarDateAnchor
    }

    /// 슬라이드 transition을 위한 월 식별자 (UTC anchor of 해당 월의 1일).
    /// 같은 월 안에서 selectedDate가 바뀌어도 monthAnchor는 동일 → 슬라이드 발동 X.
    private var monthAnchor: Date? {
        let cal = Calendar.current
        let local = selectedDate.localCalendarSameDay
        let comps = cal.dateComponents([.year, .month], from: local)
        return cal.date(from: comps)?.calendarDateAnchor
    }

    /// 두 일자가 같은 (year, month) 인지 (local 기준).
    private func sameMonth(_ a: Date, _ b: Date) -> Bool {
        let cal = Calendar.current
        let la = a.localCalendarSameDay
        let lb = b.localCalendarSameDay
        return cal.component(.year, from: la) == cal.component(.year, from: lb)
            && cal.component(.month, from: la) == cal.component(.month, from: lb)
    }

    // MARK: - Cell

    @ViewBuilder
    private func cell(for date: Date) -> some View {
        let isSelected = Calendar.gmt.isDate(date, inSameDayAs: selectedDate)
        let isToday = Calendar.gmt.isDate(date, inSameDayAs: .todayCalendarAnchor)
        let inCurrentMonth = sameMonth(date, selectedDate)
        let bgFill: Color? = {
            if isSelected { return Color.accentColor }
            if isToday { return Color.accentColor.opacity(0.5) }
            return nil
        }()
        let weekStart = weekStartFor(date)
        let weekBars = weekLayouts[weekStart] ?? []
        let maxSlots = (weekBars.map { $0.slot }.max() ?? -1) + 1
        let cellBars = weekBars.filter { date >= $0.startDay && date <= $0.endDay }
        // 인접 월 cell도 indicator 표시 — 항목이 그 일자에 cover하면 dot/bar 동일하게 그림.
        // 날짜 숫자 텍스트 색만 secondary로 dim해서 월 경계 시각 분리.
        let dotIndicators = dotIndicatorsCovering(day: date)
        VStack(spacing: 2) {
            // 일자 숫자
            Text(verbatim: Self.dayNumber(date))
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(textColor(isSelected: isSelected, inMonth: inCurrentMonth))
                .frame(width: 28, height: 28)
                .background {
                    if let bgFill {
                        Circle().fill(bgFill)
                    }
                }
            // Bar zone — week 단위 slot. 인접 cell들의 같은 slot bar가 horizontally touch해 연속 line 형성.
            // 같은 week의 모든 cell이 동일한 slot 수를 가져야 row 높이 균일.
            if maxSlots > 0 {
                VStack(spacing: 2) {
                    ForEach(0..<maxSlots, id: \.self) { slot in
                        barSlotView(slot: slot, cellBars: cellBars)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            // Dot zone — 단일일자 항목만. NTD는 teal, Todo는 priority 깃발 색.
            dotsRow(indicators: dotIndicators)
        }
        .frame(maxWidth: .infinity)
    }

    /// 한 slot 위치에 bar 있으면 state별 시각으로 렌더, 없으면 clear spacer.
    /// `maxWidth: .infinity` — VStack 안에서 다른 child(좁은 dot row 등)에 맞춰 줄어들지 않고
    /// cell 전체 너비 차지 → 인접 cell과 시각적으로 연속.
    /// State 분기:
    ///   - pending: 솔리드 fill
    ///   - completed: 솔리드 fill + opacity 0.4 (희미)
    ///   - cancelled: 점선 (Path + StrokeStyle.dash)
    @ViewBuilder
    private func barSlotView(slot: Int, cellBars: [BarSegment]) -> some View {
        if let bar = cellBars.first(where: { $0.slot == slot }) {
            let color = Self.indicatorColor(kind: bar.kind, priority: bar.priority)
            switch bar.state {
            case .pending:
                Rectangle()
                    .fill(color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 3)
            case .completed:
                Rectangle()
                    .fill(color)
                    .opacity(0.25)
                    .frame(maxWidth: .infinity)
                    .frame(height: 3)
            case .cancelled:
                // GeometryReader로 cell width 측정 후 Path로 가로선을 dash 패턴 stroke.
                // 인접 cell의 dash 시작점이 0이라 cell width가 일정하면 패턴 거의 연속.
                GeometryReader { proxy in
                    Path { path in
                        let y: CGFloat = 1.5
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 3, dash: [3, 2]))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 3)
            }
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 3)
        }
    }

    /// 단일일자 항목 dot 표시. NTD=teal, Todo=priority 깃발 색.
    /// 최대 12개를 6개씩 2행으로 표시. 초과 시 마지막 자리에 "+N".
    /// Cell 안에서 leading 정렬 — 좌측부터 채워나가는 패턴이 일관됨.
    /// State 분기:
    ///   - pending: 솔리드 filled
    ///   - completed: 솔리드 filled + opacity 0.4
    ///   - cancelled: hollow circle (stroke only)
    @ViewBuilder
    private func dotsRow(indicators: [(priority: Priority, kind: ItemKind, state: IndicatorState)]) -> some View {
        let count = indicators.count
        let showOverflow = count > 12
        let visible = showOverflow ? Array(indicators.prefix(11)) : Array(indicators.prefix(12))
        let row1 = Array(visible.prefix(6))
        let row2 = Array(visible.dropFirst(6))
        VStack(alignment: .leading, spacing: 2) {
            dotsLine(items: row1)
            if !row2.isEmpty || showOverflow {
                HStack(spacing: 3) {
                    ForEach(Array(row2.enumerated()), id: \.offset) { _, ind in
                        dotView(priority: ind.priority, kind: ind.kind, state: ind.state)
                    }
                    if showOverflow {
                        Text(verbatim: "+\(count - 11)")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func dotsLine(items: [(priority: Priority, kind: ItemKind, state: IndicatorState)]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, ind in
                dotView(priority: ind.priority, kind: ind.kind, state: ind.state)
            }
        }
        .frame(height: 5)
    }

    /// 단일 dot 렌더 — state에 따라 hollow/opacity 분기.
    /// - pending: hollow circle (stroke only) — 미체크 체크박스 느낌
    /// - completed/cancelled: filled + opacity 0.25 (희미)
    /// 완료와 취소는 dot에선 동일 시각. 다일 항목은 bar 점선 vs 솔리드 희미로 구분됨.
    @ViewBuilder
    private func dotView(priority: Priority, kind: ItemKind, state: IndicatorState) -> some View {
        let color = Self.indicatorColor(kind: kind, priority: priority)
        switch state {
        case .pending:
            Circle().stroke(color, lineWidth: 1).frame(width: 5, height: 5)
        case .completed, .cancelled:
            Circle().fill(color).opacity(0.25).frame(width: 5, height: 5)
        }
    }

    private func textColor(isSelected: Bool, inMonth: Bool) -> Color {
        if isSelected { return .white }
        if !inMonth   { return Color.secondary.opacity(0.5) }  // 인접 월 dim
        return .primary
    }

    // MARK: - 인디케이터 데이터
    //
    // 항목을 단일/다일로 분류:
    //   - 단일 (1 cal day cover): dot으로 표시
    //   - 다일 (>1 cal day cover): line(bar)으로 표시, week 단위 slot 할당
    //
    // 다일 항목의 occurrence를 visible window(42일)로 expand → week 단위로 clip →
    // greedy interval scheduling으로 slot 부여 → 같은 week 안에서 겹치는 bar는 다른 slot으로 stack.

    /// 항목 한 occurrence가 cover하는 cal day 수 (1=단일, >1=다일).
    /// - NTD: startHour + duration이 cal day 경계 넘으면 다일
    /// - Routine Todo: spanDays + 1
    /// - 1회성 Todo: dueDate - startDate + 1
    private static func occurrenceSpan(of item: Item) -> Int {
        if item.itemKind == .notTodo {
            guard let dur = item.ntdDurationHourInt else { return 1 }
            let endHour = item.startHourInt + dur
            return max(1, (endHour + 23) / 24)
        }
        if item.recurrenceRule != nil {
            return item.spanDays + 1
        }
        guard let start = item.startDate else { return 1 }
        let due = item.dueDate ?? start
        let cal = Calendar.gmt
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: due)).day ?? 0
        return max(1, days + 1)
    }

    /// Visible window — 42일 grid의 첫 일자 ~ 마지막 일자.
    private var windowStart: Date { days.first ?? selectedDate }
    private var windowEnd: Date { days.last ?? selectedDate }

    /// 단일일자 항목의 인디케이터 정보 (priority, kind, state) — day에 cover되는 것만.
    /// 1회성: startDay == dueDay AND day == startDay.
    /// Routine spanDays=0: rule.occurs(on: day).
    /// NTD duration이 cal day 안에 끝나는 경우: occurrence start == day.
    /// NTD는 priority 무관 teal 색. state는 dotsRow에서 시각(솔리드/희미/hollow) 분기.
    private func dotIndicatorsCovering(day: Date) -> [(priority: Priority, kind: ItemKind, state: IndicatorState)] {
        let indicators = allItems.compactMap { item -> (Priority, ItemKind, IndicatorState)? in
            let span = Self.occurrenceSpan(of: item)
            guard span == 1 else { return nil }
            guard singleDayItemCovers(item, day: day) else { return nil }
            return (item.itemPriority, item.itemKind, indicatorState(of: item, occurrenceStart: day))
        }
        // NTD 먼저, 그 다음 priority 순.
        return indicators.sorted { a, b in
            if a.1 != b.1 { return a.1 == .notTodo }
            return Self.priorityOrder(a.0) < Self.priorityOrder(b.0)
        }
    }

    private func singleDayItemCovers(_ item: Item, day: Date) -> Bool {
        if let rule = item.recurrenceRule {
            return rule.occurs(on: day, startDate: item.startDate, endDate: item.recurrenceEndDate)
        }
        guard let start = item.startDate else { return false }
        return Calendar.gmt.isDate(day, inSameDayAs: start)
    }

    // MARK: - 다일 항목 → bar segments

    /// Visible window 안의 다일 항목 occurrence를 (item, startDay, endDay) 단위로 expand.
    /// 1회성: 항목 자체 [startDay, startDay + span - 1].
    /// Routine: 룰 occurrence start마다 [startDay, startDay + span - 1].
    /// state는 cell render에서 occurrenceStart 기준으로 계산.
    private var multiDayOccurrences: [(item: Item, startDay: Date, endDay: Date)] {
        var result: [(Item, Date, Date)] = []
        let cal = Calendar.gmt
        for item in allItems {
            let span = Self.occurrenceSpan(of: item)
            guard span > 1 else { continue }
            if let rule = item.recurrenceRule {
                // 반복 — window 안의 모든 occurrence iterate.
                // cursor는 항상 next+1일로 advance (nextOccurrence는 cursor 포함 검사 → 무한 루프 회피).
                var cursor = cal.date(byAdding: .day, value: -span, to: windowStart) ?? windowStart
                while cursor <= windowEnd {
                    guard let next = rule.nextOccurrence(after: cursor, startDate: item.startDate, endDate: item.recurrenceEndDate) else { break }
                    let startDay = cal.startOfDay(for: next)
                    let endDay = cal.date(byAdding: .day, value: span - 1, to: startDay) ?? startDay
                    if startDay > windowEnd { break }
                    if endDay >= windowStart {
                        result.append((item, startDay, endDay))
                    }
                    cursor = cal.date(byAdding: .day, value: 1, to: next) ?? next
                }
            } else {
                // 1회성.
                guard let start = item.startDate else { continue }
                let startDay = cal.startOfDay(for: start)
                let endDay = cal.date(byAdding: .day, value: span - 1, to: startDay) ?? startDay
                if endDay >= windowStart && startDay <= windowEnd {
                    result.append((item, startDay, endDay))
                }
            }
        }
        return result
    }

    /// 각 week(7일 row) 안의 bar layout. visible weeks 각각 별도 slot 할당.
    /// 같은 week에서 시간 겹치는 bar는 다른 slot으로 stack — interval scheduling greedy.
    private var weekLayouts: [Date: [BarSegment]] {
        var result: [Date: [BarSegment]] = [:]
        let occurrences = multiDayOccurrences
        let cal = Calendar.gmt
        for w in 0..<weekCount {
            let weekStart = days[w * 7]
            let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
            // week에 걸치는 occurrence를 week 경계로 clip.
            let weekBars: [BarSegment] = occurrences.compactMap { occ in
                let clipStart = max(occ.startDay, weekStart)
                let clipEnd = min(occ.endDay, weekEnd)
                if clipStart > clipEnd { return nil }
                return BarSegment(
                    startDay: clipStart,
                    endDay: clipEnd,
                    priority: occ.item.itemPriority,
                    kind: occ.item.itemKind,
                    state: indicatorState(of: occ.item, occurrenceStart: occ.startDay),
                    slot: 0
                )
            }
            result[weekStart] = Self.assignSlots(weekBars)
        }
        return result
    }

    /// Greedy slot 할당. 정렬: startDay 오름 → 길이 내림(긴 게 lower slot).
    private static func assignSlots(_ bars: [BarSegment]) -> [BarSegment] {
        let sorted = bars.sorted { a, b in
            if a.startDay != b.startDay { return a.startDay < b.startDay }
            return a.endDay > b.endDay
        }
        var assigned: [BarSegment] = []
        for bar in sorted {
            var slot = 0
            while assigned.contains(where: { $0.slot == slot && intervalOverlap($0, bar) }) {
                slot += 1
            }
            var copy = bar
            copy.slot = slot
            assigned.append(copy)
        }
        return assigned
    }

    private static func intervalOverlap(_ a: BarSegment, _ b: BarSegment) -> Bool {
        a.startDay <= b.endDay && b.startDay <= a.endDay
    }

    /// 주어진 date가 속한 week의 시작일. days array에서 일치하는 week 찾음.
    private func weekStartFor(_ date: Date) -> Date {
        let cal = Calendar.gmt
        for w in 0..<weekCount {
            let ws = days[w * 7]
            guard let we = cal.date(byAdding: .day, value: 6, to: ws) else { continue }
            if date >= ws && date <= we { return ws }
        }
        return days.first ?? date
    }

    private static func priorityOrder(_ p: Priority) -> Int {
        switch p {
        case .high:   return 0
        case .medium: return 1
        case .low:    return 2
        case .none:   return 3
        }
    }

    /// 주어진 occurrence 일자에서의 항목 상태 계산.
    /// - 1회성: `Item.status` 직접 반영 (done/failed/pending).
    /// - 반복: 해당 occurrence 일자의 `RoutineCompletion`에서 done/failed 확인. 기록 없으면 pending.
    private func indicatorState(of item: Item, occurrenceStart: Date) -> IndicatorState {
        if item.recurrenceRule == nil {
            switch item.itemStatus {
            case .done:   return .completed
            case .failed: return .cancelled
            default:      return .pending
            }
        }
        if let rc = item.routineRecord(on: occurrenceStart) {
            if rc.failed { return .cancelled }
            if rc.done   { return .completed }
        }
        return .pending
    }

    /// priority 깃발 색. AddItemView.flagColor와 동일 매핑 (이 view에서 직접 보유해 의존성 분리).
    static func flagColor(for priority: Priority) -> Color {
        switch priority {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .blue
        case .none:   return .secondary
        }
    }

    /// 인디케이터(bar/dot) 색 — kind 우선. NTD는 priority 무관 teal,
    /// Todo는 priority 깃발 색.
    static func indicatorColor(kind: ItemKind, priority: Priority) -> Color {
        if kind == .notTodo { return .teal }
        return flagColor(for: priority)
    }

    // MARK: - 포맷 helpers

    /// firstWeekday 기준으로 회전된 짧은 요일 symbols. 한국 "일/월/.../토" / 영어 "Sun/Mon/...".
    private static func weekdaySymbols() -> [String] {
        let cal = Calendar.current
        let symbols = cal.shortWeekdaySymbols  // 항상 [Sun, Mon, Tue, Wed, Thu, Fri, Sat] index 0~6
        let offset = cal.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    private static func dayNumber(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        f.locale = Locale.current
        f.dateFormat = "d"
        return f.string(from: date)
    }
}

/// 한 week 안에서 다일 항목 occurrence의 segment. week 경계로 clip된 [startDay, endDay] + slot.
/// kind는 NTD 식별용 — Todo는 priority 깃발 색, NTD는 별도 색(teal).
/// state는 시각 표현 분기 — pending=솔리드, completed=희미, cancelled=점선.
private struct BarSegment: Hashable {
    let startDay: Date
    let endDay: Date
    let priority: Priority
    let kind: ItemKind
    let state: IndicatorState
    var slot: Int
}

/// 인디케이터(dot/bar) 상태별 시각.
enum IndicatorState: Hashable {
    case pending     // 진행 중 — 솔리드
    case completed   // 완료 — opacity 0.4 솔리드
    case cancelled   // 취소(Todo .failed) 또는 포기(NTD .failed) — 점선/hollow
}

#Preview {
    @Previewable @State var selected: Date = .todayCalendarAnchor
    @Previewable @State var forward: Bool = true
    return MonthGridView(
        selectedDate: selected,
        forward: forward,
        onSelectDate: { date in
            forward = date > selected
            selected = date
        },
        onShiftMonth: { delta in
            let cal = Calendar.current
            let local = selected.localCalendarSameDay
            if let next = cal.date(byAdding: .month, value: delta, to: local) {
                forward = delta > 0
                selected = next.calendarDateAnchor
            }
        }
    )
    .padding()
}
