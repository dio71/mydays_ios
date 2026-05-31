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

    /// 모든 active 항목 — Someday 제외, 삭제(status=2) 제외. cell 인디케이터(dot) 계산용.
    /// 일자별로 어떤 항목이 cover하는지 매 render마다 계산. 100여개 항목 × 42 cells 정도면 무시 가능 비용.
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Item.startDate)],
        predicate: NSPredicate(format: "status != 2 AND isSomeday == NO"),
        animation: .default
    )
    private var allItems: FetchedResults<Item>

    /// dot/bar 인디케이터용 Todo items — 목표(절제/활동/집중/습관)는 별도 achievement fill로 표시되므로 제외.
    /// 카테고리 필터 적용. goalKindFilter는 Todo 인디케이터에 의미 없음 (목표 한정 필터라 Todo 0개) → 빈 배열.
    /// pickedItemID 활성 시 그 Todo 항목 1개만. 목표가 picked면 Todo 0개 (목표는 achievement fill로 별도 표시).
    private var todoIndicatorItems: [Item] {
        if let id = pickedItemID {
            let match = allItems.filter { $0.id == id && $0.itemKind == .todo }
            return match
        }
        if goalKindFilter != nil { return [] }
        if let id = categoryFilter {
            return allItems.filter { $0.itemKind == .todo && $0.category?.id == id }
        }
        return allItems.filter { $0.itemKind == .todo }
    }

    var body: some View {
        // TodayView/WeekStripView와 동일한 transition 패턴.
        let insertionEdge: Edge = forward ? .trailing : .leading
        let removalEdge: Edge = forward ? .leading : .trailing
        // **퍼포먼스 critical**: 모든 caches는 body 진입 1회만 계산해 cell에 inject.
        // - layouts/dotsCache: Todo 인디케이터 (dot/bar) — 목표 제외 (todoIndicatorItems)
        // - rates: 목표 4-type 종합 달성률 — achievement fill circle용
        let layouts = weekLayouts
        let dotsCache: [Date: DotsByDay] = days.reduce(into: [:]) { dict, day in
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
                                    layouts: layouts,
                                    dots: dotsCache[day] ?? (noTime: [], am: [], pm: []),
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

    /// dotIndicators 반환 타입 — body의 dotsCache 타입과 cell parameter에서 공유.
    fileprivate typealias DotsByDay = (noTime: [DotIndicator], am: [DotIndicator], pm: [DotIndicator])

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
    private func cell(for date: Date, layouts: [Date: [BarSegment]], dots: DotsByDay, achievementRate: Double?) -> some View {
        let isSelected = Calendar.gmt.isDate(date, inSameDayAs: selectedDate)
        let isToday = Calendar.gmt.isDate(date, inSameDayAs: .todayCalendarAnchor)
        let inCurrentMonth = sameMonth(date, selectedDate)
        let weekStart = weekStartFor(date)
        let weekBars = layouts[weekStart] ?? []
        let maxSlots = (weekBars.map { $0.slot }.max() ?? -1) + 1
        let cellBars = weekBars.filter { date >= $0.startDay && date <= $0.endDay }
        VStack(spacing: 2) {
            // 일자 숫자 + 목표 achievement circle.
            // 3 단계 시각:
            //   100%: solid fill + 흰 숫자
            //   (0%, 100%): 옅은 fill (opacity 0.3) + primary 숫자
            //   0% / 활성 없음: 시각 없음 (그냥 숫자)
            // Fill 색상: aggregate(전체 종합)는 accent, pickedItem(단일 목표 선택) 시 그 목표의 iconColorHex.
            // Today: 우상단 작은 red dot. Selected: 굵은 accent stroke 2.5pt.
            let achievementFull: Bool = (achievementRate ?? 0) >= 1.0
            let fillColor: Color = pickedGoalColor ?? Color.accentColor
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if let rate = achievementRate, rate >= 1.0 {
                        Circle().fill(fillColor)
                    } else if let rate = achievementRate, rate > 0 {
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

            // Bar zone — Todo 다일 항목 (week 단위 slot, 인접 cell 연속).
            if maxSlots > 0 {
                VStack(spacing: 1) {
                    ForEach(0..<maxSlots, id: \.self) { slot in
                        barSlotView(slot: slot, cellBars: cellBars, cellDate: date)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            // Dot zone — Todo 단일일자 항목 (시간 미설정 사각 / 시간 있는 AM·PM 분할 원).
            dotsZone(noTime: dots.noTime, am: dots.am, pm: dots.pm)
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

    /// 한 slot 위치에 bar 있으면 state별 시각으로 렌더, 없으면 clear spacer.
    /// `maxWidth: .infinity` — VStack 안에서 다른 child에 맞춰 줄어들지 않고 cell 전체 너비 차지.
    ///
    /// **시간 기반 fractional offset**:
    /// cellDate가 bar.startDay이면 leading = (startHour/24) * cellWidth, bar.endDay이면 trailing = (24-endHour)/24 * cellWidth.
    /// Week 경계로 clip된 segment의 시작/끝은 hour 0/24이므로 자동 0 padding (연속 line).
    ///
    /// **State별 시각**:
    ///   - pending: 3pt solid (정상 두께)
    ///   - completed: 3pt solid + opacity 0.25 (희미)
    ///   - cancelled: 1.5pt solid (얇은 두께로 약화, 슬롯 가운데 정렬)
    @ViewBuilder
    private func barSlotView(slot: Int, cellBars: [BarSegment], cellDate: Date) -> some View {
        if let bar = cellBars.first(where: { $0.slot == slot }) {
            let color = Self.indicatorColor(colorHex: bar.colorHex)
            GeometryReader { proxy in
                let w = proxy.size.width
                let edges = barEdgeOffsets(bar: bar, cellDate: cellDate, cellWidth: w)
                // 모든 state 동일 두께(1pt) — 가는 라인으로 통일. 시각 차이는 opacity로만 표현.
                // 3pt 슬롯 안 vertical center.
                switch bar.state {
                case .pending:
                    Rectangle()
                        .fill(color)
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.leading, edges.leading)
                        .padding(.trailing, edges.trailing)
                case .completed:
                    Rectangle()
                        .fill(color)
                        .opacity(0.25)
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.leading, edges.leading)
                        .padding(.trailing, edges.trailing)
                case .cancelled:
                    Rectangle()
                        .fill(color)
                        .opacity(0.25)
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.leading, edges.leading)
                        .padding(.trailing, edges.trailing)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 3)
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 3)
        }
    }

    /// Bar의 leading/trailing 오프셋(px). 시간 기반 fractional + 보이는 edge만 min padding 보장.
    /// - 위치 계산: cell 양 끝 기준 (패딩 없이) startHour/endHour fraction.
    /// - Min padding: bar의 visible edge일 때만 1pt 최소 보장 (week boundary 연속 구간은 0 유지).
    private func barEdgeOffsets(bar: BarSegment, cellDate: Date, cellWidth: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        let isStart = Calendar.gmt.isDate(cellDate, inSameDayAs: bar.startDay)
        let isEnd = Calendar.gmt.isDate(cellDate, inSameDayAs: bar.endDay)
        let minPad: CGFloat = 1
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
        if isStart && bar.startHour > 0 {
            leading = max(CGFloat(bar.startHour) / 24.0 * cellWidth, minPad)
        }
        if isEnd && bar.endHour < 24 {
            trailing = max(CGFloat(24 - bar.endHour) / 24.0 * cellWidth, minPad)
        }
        return (leading, trailing)
    }

    /// Dot zone — 시간 없는 사각 dot row + 시간 있는 AM/PM 분할 원 dot rows.
    /// 둘 다 비어있으면 zone 자체가 비어 공간 차지 X.
    @ViewBuilder
    private func dotsZone(noTime: [DotIndicator], am: [DotIndicator], pm: [DotIndicator]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !noTime.isEmpty {
                squareDotsRow(indicators: noTime)
            }
            if !am.isEmpty || !pm.isEmpty {
                timeDotsRows(am: am, pm: pm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 시간 미설정 항목 사각 dot — 한 줄, max 6 + "+N". 가운데 정렬.
    @ViewBuilder
    private func squareDotsRow(indicators: [DotIndicator]) -> some View {
        let count = indicators.count
        let showOverflow = count > 6
        let visible = showOverflow ? Array(indicators.prefix(5)) : Array(indicators.prefix(6))
        HStack(spacing: 3) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, ind in
                squareDotView(colorHex: ind.colorHex, state: ind.state)
            }
            if showOverflow {
                Text(verbatim: "+\(count - 5)")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        // stroke spill 포함 높이 (5pt + lineWidth 1pt).
        .frame(height: 6)
    }

    /// 시간 설정 항목 원 dot — cell 좌(AM, hour<13) / 우(PM, hour>=13) 분할, 각 행 최대 3.
    /// 두 그룹 행 수가 다르면 max 행수만큼 row 생성, 모자란 쪽은 빈 자리.
    @ViewBuilder
    private func timeDotsRows(am: [DotIndicator], pm: [DotIndicator]) -> some View {
        let amRows = stride(from: 0, to: am.count, by: 3).map { Array(am[$0..<min($0 + 3, am.count)]) }
        let pmRows = stride(from: 0, to: pm.count, by: 3).map { Array(pm[$0..<min($0 + 3, pm.count)]) }
        let maxRows = max(amRows.count, pmRows.count)
        VStack(spacing: 2) {
            ForEach(0..<maxRows, id: \.self) { row in
                HStack(spacing: 0) {
                    halfDotsRow(items: row < amRows.count ? amRows[row] : [])
                    halfDotsRow(items: row < pmRows.count ? pmRows[row] : [])
                }
            }
        }
    }

    /// AM 또는 PM 한 행 (cell 절반 너비), 가운데 정렬.
    @ViewBuilder
    private func halfDotsRow(items: [DotIndicator]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, ind in
                dotView(colorHex: ind.colorHex, state: ind.state)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: 6)
    }

    /// 원 dot — 시간 설정 항목용.
    /// - pending: hollow circle (stroke only)
    /// - completed/cancelled: filled + opacity 0.25
    /// stroke lineWidth=1pt → path 바깥으로 0.5pt spill. 부모 row가 leading padding 0.5pt 부담.
    @ViewBuilder
    private func dotView(colorHex: String?, state: IndicatorState) -> some View {
        let color = Self.indicatorColor(colorHex: colorHex)
        switch state {
        case .pending:
            Circle().stroke(color, lineWidth: 1).frame(width: 5, height: 5)
        case .completed, .cancelled:
            Circle().fill(color).opacity(0.25).frame(width: 5, height: 5)
        }
    }

    /// 사각 dot — 시간 미설정 Todo 전용. 원 dot과 shape로 구분.
    /// dotView와 동일하게 stroke spill 0.5pt 발생 — 부모 row가 padding으로 보정.
    @ViewBuilder
    private func squareDotView(colorHex: String?, state: IndicatorState) -> some View {
        let color = Self.indicatorColor(colorHex: colorHex)
        switch state {
        case .pending:
            Rectangle().stroke(color, lineWidth: 1).frame(width: 5, height: 5)
        case .completed, .cancelled:
            Rectangle().fill(color).opacity(0.25).frame(width: 5, height: 5)
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

    /// 단일일자 항목의 인디케이터 — 3개로 분리:
    /// - noTime: 시간 미설정 Todo (`hasExplicitTime == false`). 사각 dot.
    /// - am: 시간 설정 + hour < 13. 좌측 원 dot.
    /// - pm: 시간 설정 + hour >= 13. 우측 원 dot.
    /// NTD는 항상 startHour 있어 am/pm 중 하나에 속함.
    private func dotIndicators(day: Date) -> (noTime: [DotIndicator], am: [DotIndicator], pm: [DotIndicator]) {
        var noTime: [DotIndicator] = []
        var am: [DotIndicator] = []
        var pm: [DotIndicator] = []
        for item in todoIndicatorItems {
            let span = Self.occurrenceSpan(of: item)
            guard span == 1, singleDayItemCovers(item, day: day) else { continue }
            let state = indicatorState(of: item, occurrenceStart: day)
            let kind = item.itemKind
            // 색상 — Todo는 category color, 목표는 iconColorHex. nil이면 gray (미분류).
            let colorHex = itemIndicatorColorHex(item)
            // NTD는 항상 시간 있음. Todo는 hasExplicitTime 검사.
            if kind == .notTodo || item.hasExplicitTime {
                let hour = Int(item.startHourInt)
                let dot = DotIndicator(kind: kind, state: state, colorHex: colorHex)
                if hour < 13 { am.append(dot) }
                else { pm.append(dot) }
            } else {
                noTime.append(DotIndicator(kind: kind, state: state, colorHex: colorHex))
            }
        }
        // 각 그룹 안에서 NTD 먼저 (현재 todoIndicatorItems는 Todo only라 사실상 의미 없음).
        // colorHex 순 정렬 — 같은 카테고리는 묶이게.
        let sortFn: (DotIndicator, DotIndicator) -> Bool = { a, b in
            if a.kind != b.kind { return a.kind == .notTodo }
            return (a.colorHex ?? "") < (b.colorHex ?? "")
        }
        return (noTime.sorted(by: sortFn), am.sorted(by: sortFn), pm.sorted(by: sortFn))
    }

    private func singleDayItemCovers(_ item: Item, day: Date) -> Bool {
        if let rule = item.recurrenceRule {
            return rule.occurs(on: day, startDate: item.startDate, endDate: item.recurrenceEndDate)
        }
        guard let start = item.startDate else { return false }
        return Calendar.gmt.isDate(day, inSameDayAs: start)
    }

    // MARK: - 다일 항목 → bar segments

    /// Visible window 안의 다일 항목 occurrence — startDay/endDay + 시작·종료 hour (cell offset 계산용).
    /// startHour: occurrence 시작 시(0~23). endHour: 마지막 cell 안의 종료 시(0~24, 24=cell 끝).
    /// 1회성/반복 Todo: item.startHourInt / dueHourInt.
    /// NTD: startHourInt + 누적 종료를 span으로 보정 — endHour = totalEnd - (span-1)*24.
    private var multiDayOccurrences: [(item: Item, startDay: Date, endDay: Date, startHour: Int, endHour: Int)] {
        var result: [(Item, Date, Date, Int, Int)] = []
        let cal = Calendar.gmt
        for item in todoIndicatorItems {
            let span = Self.occurrenceSpan(of: item)
            guard span > 1 else { continue }
            // 시작·종료 hour 계산 — 모든 occurrence가 같은 값 (반복도 동일 시간).
            let startHour = Int(item.startHourInt)
            let endHour: Int
            if item.itemKind == .notTodo, let dur = item.ntdDurationHourInt {
                let totalEnd = startHour + Int(dur)
                endHour = totalEnd - (span - 1) * 24
            } else {
                endHour = Int(item.dueHourInt)
            }
            if let rule = item.recurrenceRule {
                var cursor = cal.date(byAdding: .day, value: -span, to: windowStart) ?? windowStart
                while cursor <= windowEnd {
                    guard let next = rule.nextOccurrence(after: cursor, startDate: item.startDate, endDate: item.recurrenceEndDate) else { break }
                    let startDay = cal.startOfDay(for: next)
                    let endDay = cal.date(byAdding: .day, value: span - 1, to: startDay) ?? startDay
                    if startDay > windowEnd { break }
                    if endDay >= windowStart {
                        result.append((item, startDay, endDay, startHour, endHour))
                    }
                    cursor = cal.date(byAdding: .day, value: 1, to: next) ?? next
                }
            } else {
                guard let start = item.startDate else { continue }
                let startDay = cal.startOfDay(for: start)
                let endDay = cal.date(byAdding: .day, value: span - 1, to: startDay) ?? startDay
                if endDay >= windowStart && startDay <= windowEnd {
                    result.append((item, startDay, endDay, startHour, endHour))
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
                // Week 경계로 clip된 경우 그 끝은 cell 양 끝까지 채움 (hour=0 / 24).
                let segStartHour = (clipStart == occ.startDay) ? occ.startHour : 0
                let segEndHour = (clipEnd == occ.endDay) ? occ.endHour : 24
                return BarSegment(
                    startDay: clipStart,
                    endDay: clipEnd,
                    kind: occ.item.itemKind,
                    state: indicatorState(of: occ.item, occurrenceStart: occ.startDay),
                    startHour: segStartHour,
                    endHour: segEndHour,
                    colorHex: itemIndicatorColorHex(occ.item),
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

/// 한 week 안에서 다일 항목 occurrence의 segment. week 경계로 clip된 [startDay, endDay] + slot.
/// kind는 NTD 식별용 — Todo는 priority 깃발 색, NTD는 별도 색(teal).
/// state는 시각 표현 분기 — pending=솔리드, completed=희미, cancelled=점선.
/// startHour/endHour — bar의 cell 안 시작/종료 시각(0~24).
/// week 경계로 clip된 segment에서 실제 occurrence start가 아니면 startHour=0,
/// 실제 occurrence end가 아니면 endHour=24 (양 끝까지 채움).
/// 0 → cell 왼쪽 edge부터, 24 → cell 오른쪽 edge까지.
private struct BarSegment: Hashable {
    let startDay: Date
    let endDay: Date
    let kind: ItemKind
    let state: IndicatorState
    let startHour: Int
    let endHour: Int
    /// 인디케이터 색상 — Todo는 category color, 목표는 iconColorHex. nil이면 gray (미분류).
    let colorHex: String?
    var slot: Int
}

/// 인디케이터(dot/bar) 상태별 시각.
enum IndicatorState: Hashable {
    case pending     // 진행 중 — 솔리드
    case completed   // 완료 — opacity 0.4 솔리드
    case cancelled   // 취소(Todo .failed) 또는 포기(NTD .failed) — 점선/hollow
}

/// 단일일자 dot 정보 — priority/kind/state. hour 정보는 별도 그룹(am/pm/noTime)으로 분리해 보관.
private struct DotIndicator: Hashable {
    let kind: ItemKind
    let state: IndicatorState
    /// Todo는 category color, 목표는 iconColorHex. nil이면 gray (미분류).
    let colorHex: String?
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
