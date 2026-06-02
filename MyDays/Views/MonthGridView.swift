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

    /// 카테고리 필터 — nil이면 무관. TodayView 상단 필터 메뉴와 sync.
    var categoryFilter: UUID? = nil
    /// 목표 유형 필터 — nil이면 무관. categoryFilter와 상호 배타.
    var goalKindFilter: ItemKind? = nil
    /// 단일 항목 필터 — 항목 선택 모드에서 사용자가 picked한 item.id.
    /// nil이면 무관 (전체 종합). non-nil이면 그 item만 캘린더 표시 (Todo면 dot/bar / 목표면 achievement fill).
    var pickedItemID: UUID? = nil

    /// Dev toggle — 달성률 큰 원 표시 여부. Settings Dev section에서 변경.
    @AppStorage(UIStateKey.devShowAchievementCircle) private var showAchievementCircle: Bool = true

    /// 모든 active 항목 — Someday 제외, 삭제(status=2) 제외. cell 인디케이터(dot) 계산용.
    /// 일자별로 어떤 항목이 cover하는지 매 render마다 계산. 100여개 항목 × 42 cells 정도면 무시 가능 비용.
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Item.startDate)],
        predicate: NSPredicate(format: "status != 2 AND isSomeday == NO"),
        animation: .default
    )
    private var allItems: FetchedResults<Item>

    /// dot 인디케이터용 items — **목표 + Todo 모두 포함**. 목표는 큰 원(achievement fill)과 dot 둘 다 노출 (사용자 결정).
    /// 필터 정책:
    /// - pickedItemID: 그 1개 항목만
    /// - categoryFilter: 그 카테고리 Todo만 (목표는 카테고리 미사용)
    /// - goalKindFilter: 그 목표 type만
    /// - 기본: 전체
    private var indicatorItems: [Item] {
        if let id = pickedItemID {
            return allItems.filter { $0.id == id }
        }
        if let id = categoryFilter {
            return allItems.filter { $0.itemKind == .todo && $0.category?.id == id }
        }
        if let kind = goalKindFilter {
            return allItems.filter { $0.itemKind == kind }
        }
        return Array(allItems)
    }

    var body: some View {
        // TodayView/WeekStripView와 동일한 transition 패턴.
        let insertionEdge: Edge = forward ? .trailing : .leading
        let removalEdge: Edge = forward ? .leading : .trailing
        // **퍼포먼스 critical**: 모든 caches는 body 진입 1회만 계산해 cell에 inject.
        // - dotsCache: 단일/다일 통합 dot 인디케이터 (목표 + Todo). 정렬 적용.
        // - rates: 목표 4-type 종합 달성률 — achievement fill circle용
        let dotsCache: [Date: [DotIndicator]] = days.reduce(into: [:]) { dict, day in
            dict[day] = dotIndicators(day: day)
        }
        let rates: [Date: Double?] = days.reduce(into: [:]) { dict, day in
            dict[day] = goalAchievementRate(day: day)
        }

        VStack(spacing: 0) {
            // 요일 헤더 — firstWeekday 기준으로 회전된 short symbols.
            HStack(spacing: 0) {
                ForEach(Self.weekdaySymbols(), id: \.self) { sym in
                    Text(verbatim: sym)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
            // 요일 아래 분리선.
            Divider()

            // 일자 grid — 월 단위 transition.
            // LazyVGrid 대신 VStack of HStacks(spacing: 0)로 직접 배치 — cell 사이 간격을 정확히 0으로
            // 제어해야 다일 항목 bar가 인접 cell 경계를 넘어 시각적으로 연속됨.
            // (LazyVGrid는 column flexible 안에서 cell content를 cell width까지 늘리지 않는 quirk가 있음.)
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<weekCount, id: \.self) { weekIdx in
                        // alignment: .top — cell 마다 content 높이(dot 수 등)가 달라도 위쪽 기준 정렬해
                        // 같은 slot의 bar가 같은 y 위치에 와서 연속 line으로 보이게 함.
                        // cell 사이 vertical separator는 overlay로 — Divider를 HStack에 넣으면
                        // height claim해서 row 높이를 cell content보다 키워버림. overlay는 layout 영향 X.
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<7, id: \.self) { dayIdx in
                                let day = days[weekIdx * 7 + dayIdx]
                                cell(
                                    for: day,
                                    dots: dotsCache[day] ?? [],
                                    achievementRate: rates[day] ?? nil
                                )
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelectDate(day)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        // 각 주(row) 아래 분리선.
                        Divider()
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
    private func cell(for date: Date, dots: [DotIndicator], achievementRate: Double?) -> some View {
        let isSelected = Calendar.gmt.isDate(date, inSameDayAs: selectedDate)
        let isToday = Calendar.gmt.isDate(date, inSameDayAs: .todayCalendarAnchor)
        let inCurrentMonth = sameMonth(date, selectedDate)
        VStack(spacing: 2) {
            // 일자 숫자 + 목표 achievement circle.
            // 3 단계 시각:
            //   100%: solid fill + 흰 숫자
            //   (0%, 100%): 옅은 fill (opacity 0.3) + primary 숫자
            //   0% / 활성 없음: 시각 없음 (그냥 숫자)
            // Fill 색상: aggregate(전체 종합)는 accent, pickedItem(단일 목표 선택) 시 그 목표의 iconColorHex.
            // Today: 우상단 작은 red dot. Selected: 굵은 accent stroke 2.5pt.
            // Dev toggle OFF면 큰 원 미노출 — 숫자 색만 일반 처리.
            let displayRate: Double? = showAchievementCircle ? achievementRate : nil
            let achievementFull: Bool = (displayRate ?? 0) >= 1.0
            let fillColor: Color = pickedGoalColor ?? Color.accentColor
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if let rate = displayRate, rate >= 1.0 {
                        Circle().fill(fillColor)
                    } else if let rate = displayRate, rate > 0 {
                        Circle().fill(fillColor.opacity(0.3))
                    }
                    Text(verbatim: Self.dayNumber(date))
                        .font(.callout)
                        .foregroundStyle(numberColor(achievementFull: achievementFull, inMonth: inCurrentMonth))
                    if isSelected {
                        Circle().stroke(Color.accentColor, lineWidth: 1)
                    }
                }
                .frame(width: 28, height: 28)

                if isToday {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 4, height: 4)
                        .offset(x: 1, y: -1)
                }
            }
            .frame(width: 28, height: 28)

            // Dot zone — 단일/다일 통합. 목표(원) + 할일(사각). 최대 18개 + "+N".
            dotsZone(indicators: dots)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }

    /// 일자 숫자 색 — 100% 달성 fill 위에선 흰색 (대비), 그 외 inMonth 여부에 따라 primary/secondary.
    private func numberColor(achievementFull: Bool, inMonth: Bool) -> Color {
        if achievementFull { return .white }
        return inMonth ? Color.primary : Color.secondary
    }

    // MARK: - Goal achievement rate

    /// 그날의 목표 달성률 계산. 옵션 1: 활성 목표 개수 중 달성 비율.
    /// - 반환 nil: 미래 일자 OR 활성 목표 없음 OR 카테고리 필터 활성 (목표 표시 안 함)
    /// - 반환 0.0~1.0: done count / active count
    ///
    /// 정책:
    /// - 활성 = 그날 occurrence 있음 (반복 rule.occurs / 1회성 startDate == day)
    /// - 달성 = RC.done=true (반복) OR item.status=.done (1회성)
    /// - 포기 = 달성 안 함 (분모 포함, 분자 X)
    /// - Multi-day NTD = 시작일에만 활성 1개 카운트 (cover하는 후속일 중복 카운트 회피)
    /// - 미래 일자 = noop (계산 안 함)
    /// - **카테고리 필터**: Todo 카테고리 조망 중 → 목표 fill 무관 → 숨김 (단 pickedItemID 활성 시 무시)
    /// - **목표 유형 필터**: 해당 type만 active/done 카운트
    /// - **pickedItemID 활성**: 그 목표 1개만 — Todo면 nil 반환 (Todo는 dot/bar로 별도 표시)
    private func goalAchievementRate(day: Date) -> Double? {
        // pickedItemID 활성 시 — 그 항목이 목표면 단일 계산, Todo면 nil (Todo는 dot/bar).
        if let pid = pickedItemID {
            guard let item = allItems.first(where: { $0.id == pid }) else { return nil }
            guard item.itemKind != .todo else { return nil }
            return singleItemAchievementRate(item: item, day: day)
        }
        // 카테고리 필터 활성 시 achievement fill 숨김 — Todo 카테고리 조망에 목표는 노이즈.
        if categoryFilter != nil { return nil }
        // 미래 일자는 noop.
        if day > .todayCalendarAnchor { return nil }
        var active = 0
        var done = 0
        for item in allItems {
            let kind = item.itemKind
            // 목표 4 type만. Todo 제외.
            guard kind == .notTodo || kind == .activity || kind == .focus || kind == .habit else { continue }
            // 목표 유형 필터 활성 시 그 type만 — 선택한 type의 달성률만 표시.
            if let filterKind = goalKindFilter, kind != filterKind { continue }
            // 그날 활성 occurrence 있는지.
            if let rule = item.recurrenceRule {
                guard rule.occurs(on: day, startDate: item.startDate, endDate: item.recurrenceEndDate) else { continue }
            } else {
                // 1회성: startDate가 그날과 같은 day.
                guard let s = item.startDate, Calendar.gmt.isDate(s, inSameDayAs: day) else { continue }
            }
            active += 1
            // 달성 여부.
            if item.recurrenceRule != nil {
                // 반복: RC.done=true 있는지.
                if let rc = item.routineRecord(on: day), rc.done {
                    done += 1
                }
            } else {
                // 1회성: item.status=.done.
                if item.itemStatus == .done {
                    done += 1
                }
            }
        }
        guard active > 0 else { return nil }
        return Double(done) / Double(active)
    }

    /// 단일 목표 항목의 그날 달성률 — pickedItemID 활성 시 사용.
    /// - 활동/집중: target 대비 valueRecorded 비율 (partial progress 표시 가능)
    /// - 절제: done=1.0 / 포기=elapsed/total (포기 시각까지 진행률) / 그 외=0
    /// - 습관: binary — done이면 1.0, 아니면 0
    /// 활성 occurrence 아닌 날 OR 미래 → nil
    private func singleItemAchievementRate(item: Item, day: Date) -> Double? {
        if day > .todayCalendarAnchor { return nil }
        // 그날 활성 occurrence 있는지.
        let isActive: Bool
        if let rule = item.recurrenceRule {
            isActive = rule.occurs(on: day, startDate: item.startDate, endDate: item.recurrenceEndDate)
        } else if let s = item.startDate {
            isActive = Calendar.gmt.isDate(s, inSameDayAs: day)
        } else {
            isActive = false
        }
        guard isActive else { return nil }
        let kind = item.itemKind
        // 활동/집중 — partial progress (valueRecorded / target).
        if kind == .activity || kind == .focus {
            let stored = item.routineRecord(on: day)?.valueRecorded?.doubleValue ?? 0
            guard let target = item.activityTargetValueDouble, target > 0 else {
                return 0
            }
            return min(stored / target, 1.0)
        }
        // 절제 — done=1.0 / 포기=fractional (포기 시점까지 elapsed / total) / 그 외=0
        if kind == .notTodo {
            let isDone: Bool = {
                if item.recurrenceRule != nil {
                    return item.routineRecord(on: day)?.done == true
                }
                return item.itemStatus == .done
            }()
            if isDone { return 1.0 }
            // 포기 케이스 — partial. 1회성/반복 모두 ntdLastCompletionInstant로 포기 시각 가져옴.
            let isFailed: Bool = {
                if item.recurrenceRule != nil {
                    return item.routineRecord(on: day)?.failed == true
                }
                return item.itemStatus == .failed
            }()
            if isFailed,
               let start = item.ntdStartInstant(on: day),
               let giveUp = item.ntdLastCompletionInstant(on: day) {
                let elapsed = giveUp.timeIntervalSince(start)
                if let end = item.ntdEndInstant(on: day) {
                    let total = end.timeIntervalSince(start)
                    guard total > 0 else { return 0 }
                    return max(0, min(elapsed / total, 1.0))
                }
                // duration 미설정 NTD — 30일 cap (NTDRow progress와 동일 정책).
                let thirtyDays: TimeInterval = 30 * 24 * 3600
                return max(0, min(elapsed / thirtyDays, 1.0))
            }
            return 0
        }
        // 습관 — binary.
        let isDone: Bool = {
            if item.recurrenceRule != nil {
                return item.routineRecord(on: day)?.done == true
            }
            return item.itemStatus == .done
        }()
        return isDone ? 1.0 : 0
    }

    /// Dot zone — 단일 행 max 6, 최대 3행 (18 dot), 18+ 시 마지막 자리에 "+N".
    /// 모양: 목표 = 원, 할일 = 사각. 상태: pending=stroke, completed=filled solid, cancelled=filled opacity 0.4.
    @ViewBuilder
    private func dotsZone(indicators: [DotIndicator]) -> some View {
        guard !indicators.isEmpty else { return AnyView(EmptyView()) }
        // 최대 노출 18 (3행 × 6). 그 이상이면 17개 + "+N" 슬롯.
        let total = indicators.count
        let showOverflow = total > 18
        let visibleCount = showOverflow ? 17 : min(total, 18)
        let visible = Array(indicators.prefix(visibleCount))
        // 6개씩 행 분할.
        let rows = stride(from: 0, to: visible.count, by: 6).map { idx in
            Array(visible[idx..<min(idx + 6, visible.count)])
        }
        return AnyView(
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 3) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, ind in
                            indicatorView(ind)
                        }
                        // overflow "+N"은 마지막 행 끝에 추가.
                        if showOverflow && rowIdx == rows.count - 1 {
                            Text(verbatim: "+\(total - visibleCount)")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    /// dot view 분기 — 목표=원, 할일=사각.
    @ViewBuilder
    private func indicatorView(_ ind: DotIndicator) -> some View {
        let color = Self.indicatorColor(colorHex: ind.colorHex)
        if ind.kind == .todo {
            todoDotView(color: color, state: ind.state)
        } else {
            goalDotView(color: color, state: ind.state)
        }
    }

    /// 목표 dot (원) — pending=stroke / completed·cancelled=filled opacity 0.2 (통일).
    /// stroke은 5pt path + 1pt lineWidth → outer 6pt. filled도 6pt로 맞춰 시각 크기 통일.
    @ViewBuilder
    private func goalDotView(color: Color, state: IndicatorState) -> some View {
        switch state {
        case .pending:
            Circle().stroke(color, lineWidth: 1).frame(width: 5, height: 5)
        case .completed, .cancelled:
            Circle().fill(color).opacity(0.2).frame(width: 6, height: 6)
        }
    }

    /// 할일 dot (사각) — pending=stroke / completed·cancelled=filled opacity 0.2 (통일).
    /// stroke spill 포함 outer 6pt에 filled도 맞춤.
    @ViewBuilder
    private func todoDotView(color: Color, state: IndicatorState) -> some View {
        switch state {
        case .pending:
            Rectangle().stroke(color, lineWidth: 1).frame(width: 5, height: 5)
        case .completed, .cancelled:
            Rectangle().fill(color).opacity(0.2).frame(width: 6, height: 6)
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

    /// 일자별 dot 인디케이터 — 단일/다일 통합. 정렬: 목표 먼저 → 할일 뒤(시작 시간 기준, 시간 미지정/기간 = 0시).
    /// 다일 처리:
    /// - 일반 Todo 다일/반복: 모든 cover 일자에 dot 1개씩
    /// - NTD 다일 (목표시간 24h+): 시작일에만 1 dot (cover 일자 표시 X, 사용자 결정 예외)
    /// 미래 일자 + 목표: dot 표시 X (활성 의미 약함)
    private func dotIndicators(day: Date) -> [DotIndicator] {
        var goals: [DotIndicator] = []
        var todos: [DotIndicator] = []
        let isFuture = day > .todayCalendarAnchor
        for item in indicatorItems {
            // 그 day가 노출 대상인지 결정.
            let covers: Bool = {
                if item.itemKind == .notTodo {
                    // NTD: 시작일에만 (다일이어도 cover 일자 X).
                    return startsOnDay(item: item, day: day)
                }
                // 그 외: 다일이면 모든 cover 일자, 단일이면 시작일.
                return itemCoversDay(item, day: day)
            }()
            guard covers else { continue }
            let kind = item.itemKind
            let isGoal = kind != .todo
            // 미래 일자 + 목표는 dot 표시 X.
            if isFuture && isGoal { continue }
            let state = indicatorState(of: item, occurrenceStart: day)
            let colorHex = itemIndicatorColorHex(item)
            let sortHour = itemSortHour(item)
            let dot = DotIndicator(kind: kind, state: state, colorHex: colorHex, sortHour: sortHour)
            if isGoal { goals.append(dot) } else { todos.append(dot) }
        }
        // Todo 정렬 — 시작 시간 오름차순. 목표는 등록 순 그대로.
        todos.sort { $0.sortHour < $1.sortHour }
        // 합치기 — 목표 먼저 → 할일 뒤.
        return goals + todos
    }

    /// 그 day가 item의 occurrence start인지.
    private func startsOnDay(item: Item, day: Date) -> Bool {
        if let rule = item.recurrenceRule {
            return rule.occurs(on: day, startDate: item.startDate, endDate: item.recurrenceEndDate)
        }
        guard let start = item.startDate else { return false }
        return Calendar.gmt.isDate(day, inSameDayAs: start)
    }

    /// item이 그 day를 cover하는지 — 다일이면 [startDay, endDay] 범위 검사.
    /// 반복 다일은 이전 span 일수만큼 lookback 후 occurrence 시작일 검색.
    private func itemCoversDay(_ item: Item, day: Date) -> Bool {
        let span = Self.occurrenceSpan(of: item)
        if span == 1 {
            return startsOnDay(item: item, day: day)
        }
        let cal = Calendar.gmt
        if let rule = item.recurrenceRule {
            // 반복 다일: span만큼 lookback. 각 occurrence start가 [day-span+1, day] 안에 있나.
            var cursor = cal.date(byAdding: .day, value: -span, to: day) ?? day
            for _ in 0...(span + 1) {
                if rule.occurs(on: cursor, startDate: item.startDate, endDate: item.recurrenceEndDate) {
                    let endDay = cal.date(byAdding: .day, value: span - 1, to: cursor) ?? cursor
                    if cursor <= day && day <= endDay {
                        return true
                    }
                }
                cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            }
            return false
        }
        guard let start = item.startDate else { return false }
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.date(byAdding: .day, value: span - 1, to: startDay) ?? startDay
        return day >= startDay && day <= endDay
    }

    /// dot 정렬용 시작 시간 — Todo만 의미 있음. 시간 미지정/기간 일정 = 0시.
    private func itemSortHour(_ item: Item) -> Int {
        guard item.itemKind == .todo else { return 0 }
        let span = Self.occurrenceSpan(of: item)
        if span > 1 { return 0 }            // 기간 일정 = 0시
        if !item.hasExplicitTime { return 0 } // 시간 미지정 = 0시
        return Int(item.startHourInt)
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
        case .medium: return .yellow
        case .low:    return .blue
        case .none:   return .secondary
        }
    }

    /// 인디케이터(bar/dot) 색 — colorHex 기준 (Todo는 category, 목표는 iconColorHex).
    /// nil이면 secondary gray (미분류 / 색 미설정).
    static func indicatorColor(colorHex: String?) -> Color {
        guard let hex = colorHex, let cc = CategoryColor(rawValue: hex) else {
            return Color.secondary
        }
        return cc.color
    }

    /// 항목별 인디케이터 색 hex 추출 — Todo는 category, 목표는 iconColorHex.
    /// 둘 다 없거나 매칭 안 되면 nil (gray fallback).
    private func itemIndicatorColorHex(_ item: Item) -> String? {
        if item.itemKind == .todo {
            return item.category?.colorHex
        }
        // 목표 (절제/활동/집중/습관)
        return item.iconColorHex
    }

    /// pickedItemID 활성 + 목표일 때 그 목표의 iconColorHex → Color. 아니면 nil.
    /// achievement fill 색상에 사용 — 단일 목표 모드에서 그 목표의 정체성 색으로 표시.
    private var pickedGoalColor: Color? {
        guard let pid = pickedItemID,
              let item = allItems.first(where: { $0.id == pid }),
              item.itemKind != .todo
        else { return nil }
        return Self.indicatorColor(colorHex: item.iconColorHex)
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

/// 인디케이터(dot) 상태별 시각.
enum IndicatorState: Hashable {
    case pending     // 진행 중 — 솔리드
    case completed   // 완료 — opacity 0.4 솔리드
    case cancelled   // 취소(Todo .failed) 또는 포기(NTD .failed) — 점선/hollow
}

/// dot 인디케이터 정보 — kind/state/colorHex/정렬 키.
/// 시각: 목표 = 원, 할일 = 사각. 상태: pending=stroke, completed=filled solid, cancelled=filled opacity.
private struct DotIndicator: Hashable {
    let kind: ItemKind
    let state: IndicatorState
    /// Todo는 category color, 목표는 iconColorHex. nil이면 secondary (미분류).
    let colorHex: String?
    /// 정렬 키 — Todo만 사용 (시작 시간, 시간 미지정/기간 = 0). 목표는 0 default.
    let sortHour: Int
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
