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

    /// week row 수를 6으로 고정 (4~5주짜리 월도 빈 row로 패딩) — true면 grid 높이 일정.
    /// ActivityHistoryView처럼 monthview가 상단 고정 영역인 경우 사용 — 월 전환 시 높이 점프 회피.
    /// 기본 false (TodayView 기존 dynamic 동작 유지).
    var fixedSixRows: Bool = false

    /// 선택일 강조 시각(accent fill 원) 노출 여부. false면 일자 cell에서 selection fill 안 그림.
    /// 일자 선택 인터랙션 없는 화면(ActivityHistoryView monthview 등)에서 사용 — 의미 없는 highlight 제거.
    /// 기본 true (TodayView 기존 동작 유지).
    var showsSelection: Bool = true

    // 사용자 tint preset — @AppStorage로 직접 읽어 SwiftUI environment 풀림 회귀 방어.
    @AppStorage(AppThemeKey.tintPreset, store: .appShared)
    private var tintPresetRaw: String = TintPreset.blue.rawValue
    private var tintColor: Color {
        (TintPreset(rawValue: tintPresetRaw) ?? .blue).color
    }

    /// 모든 active 항목 — Someday 제외, 삭제(status=2) 제외. cell 인디케이터(dot) 계산용.
    /// 일자별로 어떤 항목이 cover하는지 매 render마다 계산. 100여개 항목 × 42 cells 정도면 무시 가능 비용.
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Item.startDate)],
        predicate: NSPredicate(format: "status != 2 AND isSomeday == NO"),
        animation: .default
    )
    private var allItems: FetchedResults<Item>

    /// RC 변경 observe — 활동 (+N) / 집중 세션 종료 / NTD 포기 등으로 RC가 mutate됐을 때
    /// MonthGridView body를 재실행시키기 위한 의존성 binding.
    /// Item.updatedAt bump만으론 SwiftUI가 child 관계 변경을 즉시 trigger 못 잡는 케이스가 있어
    /// RC를 직접 fetch해 변경 시점에 view가 re-evaluate되도록 강제.
    /// body에서 `_ = allCompletions.count`로 참조 (값 자체는 안 씀).
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\RoutineCompletion.completedAt, order: .reverse)],
        animation: .default
    )
    private var allCompletions: FetchedResults<RoutineCompletion>

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
        // RC FetchRequest 의존성 강제 — (+N) 활동 누적, 집중 세션 종료, 포기 등으로
        // RC가 mutate될 때 body 재실행 보장. 값 자체는 안 쓰고 count만 참조.
        let _ = allCompletions.count
        // **퍼포먼스 critical**: 모든 caches는 body 진입 1회만 계산해 cell에 inject.
        // - picked goal 모드: ring 표시 + dots 숨김.
        // - picked Todo 모드 또는 일반 모드: dots 표시 (ring 없음). Todo는 partial progress 의미 없음.
        let isPickedGoal = pickedGoalItem != nil
        let dotsCache: [Date: [DotIndicator]] = isPickedGoal
            ? [:]
            : days.reduce(into: [:]) { dict, day in dict[day] = dotIndicators(day: day) }
        let ringStates: [Date: RingState?] = isPickedGoal
            ? days.reduce(into: [:]) { dict, day in dict[day] = pickedRingState(day: day) }
            : [:]

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
                                    ring: ringStates[day] ?? nil
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
        // highPriorityGesture — 시스템 back-swipe(NavigationStack pop)와 sheet pan-to-dismiss 가로채는 케이스 방어.
        // ActivityHistoryView 같은 push된 화면에서 monthview swipe가 부모 navigation/sheet으로 전달되는 회귀 차단.
        .highPriorityGesture(
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
    /// fixedSixRows=true면 항상 42일(6주) 반환 — 월 전환 시 grid 높이 일정 유지.
    private var days: [Date] {
        guard let start = gridStart else { return [] }
        let total: Int
        if fixedSixRows {
            total = 42
        } else {
            guard let end = gridEnd else { return [] }
            total = (Calendar.gmt.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        }
        return (0..<total).compactMap {
            Calendar.gmt.date(byAdding: .day, value: $0, to: start)
        }
    }

    /// 표시할 week 수 — days.count / 7. 4~6 범위 (fixedSixRows면 항상 6).
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
    private func cell(for date: Date, dots: [DotIndicator], ring: RingState?) -> some View {
        let isSelected = Calendar.gmt.isDate(date, inSameDayAs: selectedDate)
        let isToday = Calendar.gmt.isDate(date, inSameDayAs: .todayCalendarAnchor)
        let inCurrentMonth = sameMonth(date, selectedDate)
        let isPickedGoal = pickedGoalItem != nil
        VStack(spacing: 2) {
            // 시각 layer:
            //   1. 안쪽: 선택일 = solid accent fill + 흰 글자 (WeekStripView 패턴 통일).
            //   2. 바깥: picked 모드 = ring progress (track + colored arc, Apple Watch 패턴).
            //   3. 우상단: 오늘 = 작은 red dot.
            // 일반 모드는 큰 원/링 없이 dots만 사용.
            ZStack(alignment: .topTrailing) {
                ZStack {
                    // 선택일 fill — 가장 안쪽 layer. 투명도 0.22 (글자·ring과 시각 충돌 최소).
                    // showsSelection=false면 그리지 않음 (ActivityHistoryView 등 일자 선택 없는 화면).
                    if isSelected && showsSelection {
                        Circle().fill(tintColor.opacity(0.22))
                            .frame(width: 26, height: 26)
                    }
                    // picked goal 모드 ring — 28pt 외경, 2.5pt 두께. 선택 fill보다 살짝 크게 → 둘 다 보임.
                    if isPickedGoal, let ring {
                        pickedRingView(ring: ring)
                    }
                    Text(verbatim: Self.dayNumber(date))
                        .font(.callout)
                        .foregroundStyle(numberColor(isSelected: isSelected, inMonth: inCurrentMonth))
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

            // Dot zone — picked 모드(goal/Todo 둘 다)는 8pt 고정 영역 확보해 cell 높이 일정 유지.
            //   · picked goal: ring이 메인 시각 → 빈 공간만.
            //   · picked Todo: 그 Todo dot이 있는 날만 표시 (없는 날은 빈 공간).
            //   · 일반 모드: dynamic 높이 (dotsZone이 indicator 수에 맞춰 자체 row 구성).
            // 구현: Color.clear가 항상 8pt 차지 → dotsZone이 EmptyView 반환해도 frame 보존.
            // (`Group { ... }.frame()`은 내부 EmptyView면 layout 안 잡혀 height 0이 되는 회귀 회피.)
            if pickedItemID != nil {
                Color.clear
                    .frame(height: 8)
                    .overlay(alignment: .top) {
                        if !isPickedGoal {
                            dotsZone(indicators: dots)
                        }
                    }
            } else {
                dotsZone(indicators: dots)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 일자 숫자 색 — 선택일 fill 옅어서 primary 글자도 가독성 OK. inMonth 여부만 반영.
    private func numberColor(isSelected: Bool, inMonth: Bool) -> Color {
        inMonth ? Color.primary : Color.secondary
    }

    /// picked 모드 ring rendering — Apple Watch 패턴.
    /// 28pt 외경 / 2.5pt thickness / 12시 방향 시작 / 시계 방향 fill.
    /// - pending: 옅은 track ring (활성 occurrence 신호)
    /// - partial(p): track + colored arc (0~1.0)
    /// - completed: 완전 닫힌 colored ring
    /// - cancelled: 완전 닫힌 colored ring + opacity 0.2
    @ViewBuilder
    private func pickedRingView(ring: RingState) -> some View {
        let lineWidth: CGFloat = 2.5
        switch ring.kind {
        case .pending:
            // 활성 occurrence 신호 — 옅은 track만.
            Circle()
                .stroke(ring.color.opacity(0.25), style: StrokeStyle(lineWidth: lineWidth))
                .frame(width: 28, height: 28)
        case .partial(let p):
            ZStack {
                Circle()
                    .stroke(ring.color.opacity(0.25), style: StrokeStyle(lineWidth: lineWidth))
                Circle()
                    .trim(from: 0, to: max(0, min(p, 1.0)))
                    .stroke(ring.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 28, height: 28)
        case .completed:
            Circle()
                .stroke(ring.color, style: StrokeStyle(lineWidth: lineWidth))
                .frame(width: 28, height: 28)
        case .cancelled:
            Circle()
                .stroke(ring.color.opacity(0.2), style: StrokeStyle(lineWidth: lineWidth))
                .frame(width: 28, height: 28)
        }
    }

    // MARK: - Ring state (picked 모드)

    /// picked 모드 ring 상태 산출 — 그날 해당 목표의 진행 상태를 4-state로 분류.
    /// **목표 항목만 대상** (Todo는 nil 반환 → dot 사용).
    /// **미래 일자는 nil** — 사용자 정책상 미래 ring 미노출 (오늘/과거만).
    /// - nil: 활성 occurrence 아님 / 미래 / Todo
    /// - pending: 오늘 활성 occurrence + 진행 0% (track ring만)
    /// - partial(p): 진행 중 (0 < p < 1) — 활동/집중·NTD 포기 일자
    /// - completed: target 도달 / status=done / RC.done=true
    /// - cancelled: 과거 + 미달성 / 명시 포기(RC.failed=true)
    ///
    /// 색은 picked 목표의 iconColorHex.
    /// 카테고리 필터는 ring 무관 (picked 우선).
    private func pickedRingState(day: Date) -> RingState? {
        guard let item = pickedGoalItem else { return nil }
        // 미래 일자: 사용자 정책 — 미노출.
        if day > .todayCalendarAnchor { return nil }

        // 활성 occurrence 판정.
        let isActive: Bool
        if let rule = item.recurrenceRule {
            isActive = rule.occurs(on: day, startDate: item.startDate, endDate: item.recurrenceEndDate)
        } else if let s = item.startDate {
            isActive = Calendar.gmt.isDate(s, inSameDayAs: day)
        } else {
            isActive = false
        }
        guard isActive else { return nil }

        let color = ringColor(for: item)
        let isPast = day < .todayCalendarAnchor
        let kind = item.itemKind

        // 포기/실패 우선 처리. NTD는 elapsed/total 진행률 시각화 (failedPartial), 그 외는 cancelled.
        let isFailed: Bool = {
            if item.recurrenceRule != nil {
                return item.routineRecord(on: day)?.failed == true
            }
            return item.itemStatus == .failed
        }()
        if isFailed {
            // NTD 포기: elapsed/total을 partial로 시각화 (활동/집중 진행 중과 동일 시각, 사용자 일관성).
            // 진행 0%면 cancelled로 처리 (호 안 보이는 ring보단 닫힌 시각).
            if kind == .notTodo,
               let start = item.ntdStartInstant(on: day),
               let giveUp = item.ntdLastCompletionInstant(on: day) {
                let elapsed = giveUp.timeIntervalSince(start)
                let progress: Double
                if let end = item.ntdEndInstant(on: day) {
                    let total = end.timeIntervalSince(start)
                    progress = total > 0 ? max(0, min(elapsed / total, 1.0)) : 0
                } else {
                    // duration 미설정 NTD — 30일 cap (NTDRow progress 정책과 통일).
                    let thirtyDays: TimeInterval = 30 * 24 * 3600
                    progress = max(0, min(elapsed / thirtyDays, 1.0))
                }
                if progress > 0 {
                    return RingState(kind: .partial(progress), color: color)
                }
            }
            return RingState(kind: .cancelled, color: color)
        }

        // 완료 — done flag 우선. 활동/집중은 valueRecorded vs target 직접 검사 (done flag stale 대비).
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
        if isDone { return RingState(kind: .completed, color: color) }

        // 활동/집중 partial progress — valueRecorded / target.
        if kind == .activity || kind == .focus,
           let rc = item.routineRecord(on: day) {
            let val = rc.valueRecorded?.doubleValue ?? 0
            let target = rc.targetSnapshot?.doubleValue ?? item.activityTargetValueDouble ?? 0
            if target > 0, val > 0 {
                return RingState(kind: .partial(val / target), color: color)
            }
        }

        // NTD partial progress — 시작 시각부터 현재까지 elapsed / total (duration).
        // 시작 전이면 pending. 종료 instant 도과면 completed (auto-complete 늦은 케이스).
        // duration 미설정 NTD는 30일 cap (NTDRow / 위젯 progress 정책과 통일).
        if kind == .notTodo {
            let now = Date()
            if let start = item.ntdStartInstant(on: day), start <= now {
                let elapsed = now.timeIntervalSince(start)
                let total: Double
                if let end = item.ntdEndInstant(on: day) {
                    total = end.timeIntervalSince(start)
                } else {
                    total = 30 * 24 * 3600
                }
                if total > 0 {
                    let p = elapsed / total
                    if p >= 1.0 { return RingState(kind: .completed, color: color) }
                    if p > 0    { return RingState(kind: .partial(p), color: color) }
                }
            }
        }

        // 과거 + 미달성 → cancelled (활동/집중 미완료 정책 + 다른 type도 일관 처리).
        if isPast { return RingState(kind: .cancelled, color: color) }

        // 오늘/미래 + 활성 + 미진행 → pending track.
        return RingState(kind: .pending, color: color)
    }

    /// picked 항목 색 — 목표는 iconColorHex 사용. (Todo는 ring 사용 안 함 → 이 함수 호출 안 됨.)
    private func ringColor(for item: Item) -> Color {
        Self.indicatorColor(colorHex: item.iconColorHex)
    }

    /// picked 항목이 목표(non-Todo)이면 그 item, 아니면 nil. ring 노출 여부의 source of truth.
    /// Todo는 dot 시각 유지 (partial progress 의미 없음 + 사용자 기대).
    private var pickedGoalItem: Item? {
        guard let pid = pickedItemID,
              let item = allItems.first(where: { $0.id == pid }),
              item.itemKind != .todo else { return nil }
        return item
    }

    /// Dot zone — 단일 행 max 6, 최대 3행 (18 dot), 18+ 시 마지막 자리에 "+N".
    /// 모양: 목표 = 원, 할일 = 사각. 상태: pending=stroke / completed=filled solid / cancelled=filled opacity 0.2.
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

    /// 목표 dot (원) — pending=stroke / completed=filled solid / cancelled=filled opacity 0.2.
    /// stroke은 5pt path + 1pt lineWidth → outer 6pt. filled도 6pt로 맞춰 시각 크기 통일.
    @ViewBuilder
    private func goalDotView(color: Color, state: IndicatorState) -> some View {
        switch state {
        case .pending:
            Circle().stroke(color, lineWidth: 1).frame(width: 5, height: 5)
        case .completed:
            Circle().fill(color).frame(width: 6, height: 6)
        case .cancelled:
            Circle().fill(color).opacity(0.2).frame(width: 6, height: 6)
        }
    }

    /// 할일 dot (사각) — pending=stroke / completed=filled solid / cancelled=filled opacity 0.2.
    /// stroke spill 포함 outer 6pt에 filled도 맞춤.
    @ViewBuilder
    private func todoDotView(color: Color, state: IndicatorState) -> some View {
        switch state {
        case .pending:
            Rectangle().stroke(color, lineWidth: 1).frame(width: 5, height: 5)
        case .completed:
            Rectangle().fill(color).frame(width: 6, height: 6)
        case .cancelled:
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
    /// - **활동·집중**: `rc.done` 플래그만 믿지 않고 `valueRecorded >= effectiveTarget` 직접 검사.
    ///   BG handler 실패 / 옛 빌드 done flip 버그 / target 사후 변경 등으로 done=false인 채 value 초과 가능 — 강건성 위해.
    /// - **활동·집중 + 과거 일자 + target 미달성**: cancelled 시각 (filled opacity 0.2)로 처리.
    ///   미완료 상태로 만료된 의미. 오늘 / 미래는 pending(line) 유지 — 사용자가 아직 로깅 가능.
    private func indicatorState(of item: Item, occurrenceStart: Date) -> IndicatorState {
        let kind = item.itemKind
        let isPast = occurrenceStart < .todayCalendarAnchor
        let isActivityOrFocus = (kind == .activity || kind == .focus)

        if item.recurrenceRule == nil {
            switch item.itemStatus {
            case .done:   return .completed
            case .failed: return .cancelled
            default:
                // 1회성 활동/집중 — RC value vs target 직접 비교. done flag 못 믿는 케이스 방어.
                if isActivityOrFocus, let rc = item.routineRecord(on: occurrenceStart) {
                    if rc.failed { return .cancelled }
                    let val = rc.valueRecorded?.doubleValue ?? 0
                    let target = rc.targetSnapshot?.doubleValue ?? item.activityTargetValueDouble ?? 0
                    if target > 0 && val >= target { return .completed }
                }
                // 1회성 활동/집중 + 과거 + target 미달성 → 미완료 = cancelled 시각.
                if isPast && isActivityOrFocus { return .cancelled }
                return .pending
            }
        }
        if let rc = item.routineRecord(on: occurrenceStart) {
            if rc.failed { return .cancelled }
            // 활동/집중 반복: value vs target 직접 비교 (done flag 보강).
            if isActivityOrFocus {
                let val = rc.valueRecorded?.doubleValue ?? 0
                let target = rc.targetSnapshot?.doubleValue ?? item.activityTargetValueDouble ?? 0
                if target > 0 && val >= target { return .completed }
            } else if rc.done {
                return .completed
            }
        }
        // 반복 활동/집중 + 과거 + done/failed 아님 (RC 미생성 또는 partial 누적) → 미완료 = cancelled 시각.
        if isPast && isActivityOrFocus { return .cancelled }
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

/// picked 모드 ring 상태 — 28pt 외경 ring으로 한 항목의 그날 진행도 시각화.
/// kind에 따라 pickedRingView가 다른 stroke 패턴으로 렌더링.
/// NTD 포기 시 elapsed/total도 partial 재사용 — 활동/집중 진행 중과 동일 시각 (사용자 일관성 우선).
struct RingState {
    enum Kind {
        case pending                   // 활성 occurrence + 진행 0% — 옅은 track ring
        case partial(Double)           // 진행 중 0~1 — 활동/집중 valueRecorded/target, NTD 포기 elapsed/total
        case completed                 // target 도달 / done — 완전 닫힌 색 ring
        case cancelled                 // 과거 미달성 / NTD 포기 (진행 0%) — 완전 닫힌 ring opacity 0.2
    }
    let kind: Kind
    let color: Color
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
