import CoreData
import SwiftUI

// MARK: - Cancel Mode Environment
//
// 취소 모드 플래그를 ItemRow/NTDRow까지 prop drilling 없이 전파.
// TodayView가 inject, child rows가 @Environment(\.cancelMode)로 read.
// 다른 view(ListView 등)는 default false 그대로라 영향 없음.

private struct CancelModeKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var cancelMode: Bool {
        get { self[CancelModeKey.self] }
        set { self[CancelModeKey.self] = newValue }
    }
}

struct TodayView: View {

    // displayedDate는 calendar date 의미 → UTC anchor Date로 관리.
    // 화살표/jump 동작도 모두 UTC 캘린더로 일관성 유지.
    @State private var displayedDate: Date = .todayCalendarAnchor
    // 자정 넘김 감지 기준값. 변경 감지 후 displayedDate를 ±1 범위에서 자동 shift.
    @State private var lastKnownToday: Date = .todayCalendarAnchor
    @State private var sheet: ItemSheetMode?
    // 일자 이동 방향 — slide 애니메이션 방향 제어. forward(미래) → 새 view가 우측에서 진입.
    @State private var lastNavigationForward: Bool = true
    // 취소 모드 — 메뉴에서 진입, 모든 미완료 row에 (x) 버튼 노출.
    @State private var cancelMode: Bool = false
    // 상단 영역 모드 — Day (WeekStrip) / Month (MonthGrid). TodayList 본문은 두 모드 공통.
    @State private var viewMode: TodayViewMode = .day
    // 특정일 이동 시트.
    @State private var showDatePicker: Bool = false
    @State private var datePickerSelection: Date = Date()
    // 카테고리 필터 — nil이면 "모두". ListView와 동일 패턴.
    @State private var filterCategoryID: UUID?
    @Environment(\.scenePhase) private var scenePhase

    /// 필터 메뉴용 카테고리 목록 — sortOrder 오름차순.
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Category.sortOrder), SortDescriptor(\Category.name)],
        animation: .default
    )
    private var categories: FetchedResults<Category>

    var body: some View {
        // ZStack + .id로 view identity 변경 시 transition 발동.
        // 외곽 ZStack에 .animation 부착 — implicit하게 insertion/removal animate.
        // toolbar는 ZStack 외부에 둠 — view 재생성 시 toolbar 깜빡임 방지.
        let insertionEdge: Edge = lastNavigationForward ? .trailing : .leading
        let removalEdge: Edge = lastNavigationForward ? .leading : .trailing
        ZStack {
            TodayList(date: displayedDate, categoryFilter: filterCategoryID, sheet: $sheet)
                .id(displayedDate)
                .transition(.asymmetric(
                    insertion: .move(edge: insertionEdge),
                    removal: .move(edge: removalEdge)
                ))
        }
        .clipped()
        .animation(.easeInOut(duration: 0.22), value: displayedDate)
        // 좌우 스와이프로 일자 이동 — List 세로 스크롤과 공존하도록 simultaneousGesture 사용.
        // 수평 우세 (|h| > |v|*2) + 충분한 거리(>60pt)일 때만 day shift 트리거.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    // 취소 모드에서는 일자 이동 차단 — 사용자가 취소 액션에만 집중하도록.
                    guard !cancelMode else { return }
                    let h = value.translation.width
                    let v = value.translation.height
                    guard abs(h) > abs(v) * 2, abs(h) > 60 else { return }
                    // 오른쪽 스와이프 → 이전 일자, 왼쪽 스와이프 → 다음 일자.
                    shiftDay(h > 0 ? -1 : 1)
                }
        )
        // 상단 영역 — Day 모드는 7-cell week strip, Month 모드는 7×6 month grid.
        // 두 모드 모두 일자 cell 탭 + 가로 swipe 지원. 본문의 일 단위 swipe와 영역 분리.
        // 취소 모드에서는 일자 이동 차단 (본문 swipe와 동일 정책).
        .safeAreaInset(edge: .top, spacing: 8) {
            Group {
                switch viewMode {
                case .day:
                    WeekStripView(
                        selectedDate: displayedDate,
                        forward: lastNavigationForward,
                        onSelectDate: { date in
                            guard !cancelMode else { return }
                            guard !Calendar.gmt.isDate(date, inSameDayAs: displayedDate) else { return }
                            navigateTo(date, forward: date > displayedDate)
                        },
                        onShiftWeek: { days in
                            guard !cancelMode else { return }
                            shiftDay(days)
                        }
                    )
                case .month:
                    MonthGridView(
                        selectedDate: displayedDate,
                        forward: lastNavigationForward,
                        onSelectDate: { date in
                            guard !cancelMode else { return }
                            guard !Calendar.gmt.isDate(date, inSameDayAs: displayedDate) else { return }
                            navigateTo(date, forward: date > displayedDate)
                        },
                        onShiftMonth: { delta in
                            guard !cancelMode else { return }
                            shiftMonth(delta)
                        },
                        categoryFilter: filterCategoryID
                    )
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.cancelMode, cancelMode)
        .toolbar {
            if cancelMode {
                // 취소 모드 — 우측에 체크 아이콘 버튼 (iOS 편집 모드 표준 위치).
                // iOS 26 prominent style이 자동 contrast(흰색) 처리 안 하는 환경 회피 — Image 자체에 .white 강제.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        cancelMode = false
                    } label: {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .accessibilityLabel("common.done")
                }
            } else {
                // 평시 — 우측 달력 + 카테고리 필터 + 더보기 메뉴.
                // ToolbarItemGroup으로 묶어 같은 capsule 안에 두 버튼.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        viewMode = (viewMode == .day) ? .month : .day
                    } label: {
                        Image(systemName: viewMode == .day ? "calendar" : "list.bullet")
                    }
                    categoryFilterMenu
                    Menu {
                        Button {
                            datePickerSelection = displayedDate.localCalendarSameDay
                            showDatePicker = true
                        } label: {
                            Label("today.menu.jump_date", systemImage: "calendar.badge.clock")
                        }
                        Button {
                            cancelMode = true
                        } label: {
                            Label("today.menu.cancel_mode", systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        // 하단 leading: [<] [오늘] [>] 네비게이션 그룹.
        //   - "오늘" 버튼 색상으로 상태 표시 (오늘 = accent fill, 다른 날 = gray fill)
        //   - 좌우 chevron은 일자 ±1 이동
        //   - 취소 모드 중에는 숨김 — 사용자가 취소 액션에만 집중하도록 (iOS 편집 모드 표준 패턴)
        .overlay(alignment: .bottomLeading) {
            if !cancelMode {
                let isToday = daysFromToday == 0
                HStack(spacing: 8) {
                    Button { shiftDay(-1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color(.systemGray4)))
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    }
                    Button(action: jumpToToday) {
                        Text("nav.jump_home")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isToday ? .white : Color.secondary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(isToday ? Color.accentColor : Color(.systemGray4)))
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    }
                    Button { shiftDay(1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color(.systemGray4)))
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    }
                }
                .padding(20)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // 새 항목 추가 FAB — 취소 모드 중에는 숨김.
            if !cancelMode {
                Button {
                    // 카테고리 필터 적용 중이면 그 카테고리를 신규 항목에도 preset.
                    sheet = .new(baseDate: displayedDate, categoryID: filterCategoryID)
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.accentColor))
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                }
                .padding(20)
            }
        }
            .sheet(item: $sheet) { mode in
                switch mode {
                case .new(let baseDate, let categoryID):
                    AddItemView(baseDate: baseDate, categoryID: categoryID)
                case .edit(let item):
                    AddItemView(editing: item)
                }
            }
            // 특정일 이동 sheet — graphical DatePicker로 년/월/일 선택.
            // 명시적 "이동" 버튼으로 confirm — DatePicker가 wheel scroll과 일자 탭 onChange를 구분 못해서
            // 자동 닫힘 방식은 wheel 조작 시 의도 못 살림. 인접월 cell 탭도 자연 처리.
            // selection은 local Date, displayedDate는 UTC anchor — 양방향 변환 필요.
            .sheet(isPresented: $showDatePicker) {
                NavigationStack {
                    DatePicker(
                        "today.menu.jump_date",
                        selection: $datePickerSelection,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .padding(.horizontal)
                    .navigationTitle("today.menu.jump_date")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("common.close") { showDatePicker = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("today.menu.jump_date.confirm") {
                                let target = datePickerSelection.calendarDateAnchor
                                if !Calendar.gmt.isDate(target, inSameDayAs: displayedDate) {
                                    navigateTo(target, forward: target > displayedDate)
                                }
                                showDatePicker = false
                            }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            // 자정 넘김 시 — Foreground 중이면 NSCalendarDayChanged fire,
            // 백그라운드에서 자정 통과 후 복귀하면 scenePhase==.active로 잡음.
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                handleDayChange()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { handleDayChange() }
            }
            // 다른 탭으로 이동 시 취소 모드 자동 종료 — 사용자가 돌아왔을 때 clean state.
            .onDisappear {
                cancelMode = false
            }
    }

    /// 자정/멀티-일 백그라운드 복귀 처리.
    /// displayedDate가 직전 today 기준 ±1일(어제/오늘/내일)이었으면 같은 dayDelta만큼 forward shift.
    /// 모레+ 이후로 명시적으로 navigate한 경우는 절대 날짜 유지 — 사용자 의도 보존.
    private func handleDayChange() {
        let newToday = Date.todayCalendarAnchor
        guard !Calendar.gmt.isDate(newToday, inSameDayAs: lastKnownToday) else { return }
        let dayDelta = Calendar.gmt.dateComponents([.day], from: lastKnownToday, to: newToday).day ?? 0
        let diff = Calendar.gmt.dateComponents([.day], from: lastKnownToday, to: displayedDate).day ?? 0
        if abs(diff) <= 1, dayDelta != 0,
           let shifted = Calendar.gmt.date(byAdding: .day, value: dayDelta, to: displayedDate) {
            displayedDate = shifted
        }
        lastKnownToday = newToday
    }

    private func shiftDay(_ value: Int) {
        guard let next = Calendar.gmt.date(byAdding: .day, value: value, to: displayedDate) else { return }
        navigateTo(next, forward: value > 0)
    }

    private func jumpToToday() {
        let today: Date = .todayCalendarAnchor
        guard !Calendar.gmt.isDate(displayedDate, inSameDayAs: today) else { return }
        navigateTo(today, forward: displayedDate < today)
    }

    /// 일자 이동 공통 — 방향 바뀔 때 direction state를 먼저 업데이트(한 박자 먼저)해서
    /// 기존 view의 removal transition도 새 방향으로 재캡처되게 함.
    /// 직접 같은 cycle에서 둘 다 바꾸면 SwiftUI가 old view의 transition을 이전 capture값으로 적용해
    /// "한 방향으로만 자연스럽고 방향 바꾸면 같은 쪽으로 사라지는" 버그 발생.
    private func navigateTo(_ date: Date, forward: Bool) {
        if forward != lastNavigationForward {
            lastNavigationForward = forward
            // 다음 run loop에서 displayedDate 변경 — old view가 새 transition으로 re-capture된 상태에서 removal.
            DispatchQueue.main.async {
                displayedDate = date
            }
        } else {
            displayedDate = date
        }
    }

    /// 카테고리 필터 Menu — "모두" + 각 카테고리. 활성 시 아이콘 filled.
    /// ListView.categoryFilterMenu와 동일 패턴.
    @ViewBuilder
    private var categoryFilterMenu: some View {
        Menu {
            Button {
                filterCategoryID = nil
            } label: {
                if filterCategoryID == nil {
                    Label("list.filter.all", systemImage: "checkmark")
                } else {
                    Text("list.filter.all")
                }
            }
            ForEach(categories, id: \.id) { cat in
                Button {
                    filterCategoryID = cat.id
                } label: {
                    if filterCategoryID == cat.id {
                        Label(cat.name ?? "", systemImage: "checkmark")
                    } else {
                        Label {
                            Text(verbatim: cat.name ?? "")
                        } icon: {
                            Image(systemName: cat.iconName ?? CategoryIcon.defaultIcon.symbolName)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: filterCategoryID == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private var daysFromToday: Int {
        // 둘 다 UTC anchor → UTC 캘린더로 일수 차 계산.
        let today: Date = .todayCalendarAnchor
        return Calendar.gmt.dateComponents([.day], from: today, to: displayedDate).day ?? 0
    }

    private var navigationTitle: String {
        // Day 모드: "M월 d일 (요일)" — 오늘/어제/내일도 절대 날짜로 표시.
        // Month 모드: "yyyy년 M월" — 현재 표시 중인 월 명시.
        // UTC anchor → formatter도 UTC로.
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        if viewMode == .month {
            let f = DateFormatter()
            f.locale = Locale.current
            f.timeZone = utc
            f.setLocalizedDateFormatFromTemplate("yMMMM")
            return f.string(from: displayedDate)
        }
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale.current
        weekdayFormatter.timeZone = utc
        weekdayFormatter.setLocalizedDateFormatFromTemplate("EEE")
        let weekday = weekdayFormatter.string(from: displayedDate)

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = utc
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let dateStr = formatter.string(from: displayedDate)

        return "\(dateStr) (\(weekday))"
    }

    /// Month 모드용 — displayedDate를 ±N개월 이동. 같은 day-of-month로 매핑 (월 일수 부족 시 systemClamping).
    /// 본문 ZStack의 slide transition도 함께 발동.
    private func shiftMonth(_ delta: Int) {
        let cal = Calendar.current
        let local = displayedDate.localCalendarSameDay
        guard let nextLocal = cal.date(byAdding: .month, value: delta, to: local) else { return }
        let next = nextLocal.calendarDateAnchor
        navigateTo(next, forward: delta > 0)
    }
}

/// TodayView 상단 영역 모드 — Day(week strip) / Month(month grid).
enum TodayViewMode { case day, month }

struct TodayList: View {

    let date: Date
    /// 카테고리 필터 — nil이면 "모두". 매 fetch 결과를 view-side filter (ListView와 동일 패턴).
    let categoryFilter: UUID?
    @Binding var sheet: ItemSheetMode?
    /// 취소 모드 — 부모 TodayView가 environment로 inject. row tap 시 편집 sheet 차단.
    @Environment(\.cancelMode) private var cancelMode

    /// 할일(1회성+루틴) 정렬 snapshot — date 변경 시(view 재생성) 한 번 계산.
    /// 같은 date 내에서 체크/취소 토글 시 즉시 reorder되지 않게 cache. 다음 navigation 시 재계산.
    @State private var stableActivityOrder: [String] = []

    /// 통합 fetch — displayedDay가 [startDate, dueDate] 구간 안에 있는 모든 active 1회성 Todo.
    /// 시작·진행·마감 섹션 분류는 view-side `classify(_:now:)`에서 시간 instant 기반으로 동적.
    @FetchRequest var allActiveTodos: FetchedResults<Item>
    @FetchRequest var routineItems: FetchedResults<Item>
    @FetchRequest var ntdItems: FetchedResults<Item>

    /// section header에서 활성 카테고리 lookup용.
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Category.sortOrder), SortDescriptor(\Category.name)],
        animation: .default
    )
    private var categories: FetchedResults<Category>

    init(date: Date, categoryFilter: UUID?, sheet: Binding<ItemSheetMode?>) {
        self.date = date
        self.categoryFilter = categoryFilter
        self._sheet = sheet
        // date는 UTC anchor. FetchRequest predicate의 [start, end) 범위도 UTC 자정 기준으로 계산해
        // 저장된 startDate/dueDate(UTC anchor)와 정확히 비교되도록 한다.
        let start = Calendar.gmt.startOfDay(for: date)
        let end = Calendar.gmt.date(byAdding: .day, value: 1, to: start) ?? start
        let sort = [SortDescriptor(\Item.priority, order: .reverse), SortDescriptor(\Item.createdAt)]

        // displayedDay가 [startDate, dueDate] 구간 안에 있는 1회성:
        //   (startDate == nil OR startDate < end) AND (dueDate == nil OR dueDate >= start)
        // status != 2 — pending(0) + done(1) + failed(3) 모두 포함. 완료 항목도 그날 화면에 잔류 표시.
        //
        // 오늘 페이지(date == .todayCalendarAnchor)에 한해 overdue 미체크(dueDate < start AND status==0) 추가.
        // 다른 날짜 페이지는 기존 범위 그대로.
        let todayAnchor = Date.todayCalendarAnchor
        let isTodayPage = Calendar.gmt.isDate(date, inSameDayAs: todayAnchor)
        let predicateFormat: String
        let predicateArgs: [NSDate]
        if isTodayPage {
            predicateFormat = "status != 2 AND recurrenceRule == nil AND kind == 0 AND isSomeday == NO "
                            + "AND (startDate == nil OR startDate < %@) "
                            + "AND ((dueDate == nil OR dueDate >= %@) OR (dueDate < %@ AND status == 0))"
            predicateArgs = [end as NSDate, start as NSDate, start as NSDate]
        } else {
            predicateFormat = "status != 2 AND recurrenceRule == nil AND kind == 0 AND isSomeday == NO "
                            + "AND (startDate == nil OR startDate < %@) "
                            + "AND (dueDate == nil OR dueDate >= %@)"
            predicateArgs = [end as NSDate, start as NSDate]
        }
        _allActiveTodos = FetchRequest(
            sortDescriptors: sort,
            predicate: NSPredicate(format: predicateFormat, argumentArray: predicateArgs),
            animation: .default
        )
        _routineItems = FetchRequest(
            sortDescriptors: sort,
            predicate: NSPredicate(
                format: "recurrenceRule != nil AND status != 2 AND kind == 0"
            ),
            animation: .default
        )
        // NTD section 후보: 삭제(2)되지 않은 NTD 전체. occurrence 필터·완료/포기 분기는 view-side에서.
        // status 1(done)·3(failed)인 1회성 NTD도 "오늘 종료된 것"은 오늘 화면에 남겨야 하므로 포함.
        _ntdItems = FetchRequest(
            sortDescriptors: [SortDescriptor(\Item.createdAt)],
            predicate: NSPredicate(format: "kind == 1 AND status != 2"),
            animation: .default
        )
    }

    // 단순 섹션 분류는 `Item.todoSection(on:now:)` 공용 helper 사용 (Item+Helpers).

    /// (item, occurrence) 쌍 — 같은 Item이 여러 occurrence로 노출될 때 ForEach id 충돌 회피.
    /// id는 objectID + occurrence timestamp 조합.
    struct OccurrenceRow: Identifiable {
        let item: Item
        let occurrenceDate: Date
        var id: String {
            "\(item.objectID.uriRepresentation().absoluteString)|\(Int(occurrenceDate.timeIntervalSince1970))"
        }
    }

    /// displayedDate에 표시할 NTD occurrence 목록.
    ///
    /// 원칙:
    ///   - displayedDate가 occurrence의 노출 범위 [start ~ end] 안에 있으면 표시
    ///     · end = duration 설정됨: 계획된 종료 instant의 local 일자
    ///     · end = duration 없음 + RC/Item.completedAt: 그 instant의 local 일자
    ///     · end = duration 없음 + 진행 중: now의 local 일자
    ///   - 완료/포기 occurrence도 노출 범위 안에 있는 한 표시 (NTDRow가 상태 라벨 처리)
    ///   - 같은 Item의 multi-day 겹침 시 **모든 매치 occurrence 노출** (그룹핑은 추후).
    /// categoryFilter 적용 — nil이면 모두 통과, 그 외 item.category?.id 매칭.
    private func matchesCategoryFilter(_ item: Item) -> Bool {
        guard let id = categoryFilter else { return true }
        return item.category?.id == id
    }

    private var ntdsForDate: [OccurrenceRow] {
        let now = Date()
        var result: [OccurrenceRow] = []

        for item in ntdItems where matchesCategoryFilter(item) {
            let candidates = item.ntdOccurrenceStartCandidates(coveringDate: date)
            for occDate in candidates {
                let range = item.ntdOccurrenceCalendarRange(occurrenceDate: occDate, now: now)
                if range.start <= date && date <= range.end {
                    result.append(OccurrenceRow(item: item, occurrenceDate: occDate))
                }
            }
        }
        return result
    }

    /// 반복 항목 occurrence 목록. multi-day 겹침 시 같은 Item의 여러 occurrence 모두 반환.
    /// `Item.occurrenceStartsCovering(date:)`로 cover하는 모든 start dates 수집.
    private var routinesForDate: [OccurrenceRow] {
        var result: [OccurrenceRow] = []
        for item in routineItems where matchesCategoryFilter(item) {
            for start in item.occurrenceStartsCovering(date: date) {
                result.append(OccurrenceRow(item: item, occurrenceDate: start))
            }
        }
        return result
    }

    /// 할일(1회성+루틴) 표시 list — snapshot 적용.
    /// stableActivityOrder가 비어있으면 fresh sort (첫 render), 있으면 cached order로 재배치.
    /// 새 row는 cache에 없는 ID라 끝에 append됨.
    private func displayActivities() -> [OccurrenceRow] {
        let current = todoActivityRows()
        if stableActivityOrder.isEmpty {
            return sortedActivities()
        }
        let idMap = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var result: [OccurrenceRow] = []
        var seen: Set<String> = []
        for id in stableActivityOrder {
            if let row = idMap[id] {
                result.append(row)
                seen.insert(id)
            }
        }
        for row in current where !seen.contains(row.id) {
            result.append(row)
        }
        return result
    }

    /// 1회성 Todo + 반복 Todo(루틴)를 OccurrenceRow 단일 list로 통합.
    /// 1회성은 occurrence 1개 (startDate). 루틴은 occurrenceStartsCovering이 multi-occurrence.
    private func todoActivityRows() -> [OccurrenceRow] {
        let now = Date()
        var result: [OccurrenceRow] = []
        // 1회성 Todo: todoSection 매치되는 항목을 OccurrenceRow(occurrence = startDate)로 변환.
        // categoryFilter 적용 — nil이면 모두 통과.
        for item in allActiveTodos where matchesCategoryFilter(item) {
            guard item.recurrenceRule == nil else { continue }
            guard item.todoSection(on: date, now: now) != nil else { continue }
            let occ = item.startDate ?? date
            result.append(OccurrenceRow(item: item, occurrenceDate: occ))
        }
        // 루틴: routinesForDate가 자체적으로 filter 적용.
        result.append(contentsOf: routinesForDate)
        return result
    }

    /// 할일 섹션 정렬:
    ///   1) 같은 Item의 occurrence들은 항상 인접 (chronological)
    ///   2) Item 그룹 단위: pending 그룹 먼저 → 전부 done인 그룹은 끝
    ///   3) 같은 bucket 내: priority desc (high → none) → sortAnchor asc (시간 가까운 것 먼저)
    /// 그룹 단위 split으로 같은 Item이 bucket 사이 쪼개지지 않음.
    private func sortedActivities() -> [OccurrenceRow] {
        let now = Date()
        let raw = todoActivityRows()
        var byItem: [NSManagedObjectID: [OccurrenceRow]] = [:]
        var itemOrder: [NSManagedObjectID] = []
        for row in raw {
            if byItem[row.item.objectID] == nil { itemOrder.append(row.item.objectID) }
            byItem[row.item.objectID, default: []].append(row)
        }
        // 각 그룹 내 occurrence를 chronological 순으로.
        for id in itemOrder {
            byItem[id]?.sort { $0.occurrenceDate < $1.occurrenceDate }
        }
        var pendingGroups: [[OccurrenceRow]] = []
        var doneGroups: [[OccurrenceRow]] = []
        for itemID in itemOrder {
            guard let group = byItem[itemID] else { continue }
            let hasAnyPending = group.contains { !$0.item.isCompletedForDate($0.occurrenceDate) }
            if hasAnyPending { pendingGroups.append(group) } else { doneGroups.append(group) }
        }
        // 그룹 정렬 키 — pending 그룹은 첫 pending occurrence 기준, done 그룹은 첫 row 기준.
        pendingGroups.sort { a, b in
            let ra = Self.pendingRepresentative(of: a)
            let rb = Self.pendingRepresentative(of: b)
            let pa = Self.priorityOrder(ra.item.itemPriority)
            let pb = Self.priorityOrder(rb.item.itemPriority)
            if pa != pb { return pa < pb }
            return Self.sortAnchor(for: ra, now: now) < Self.sortAnchor(for: rb, now: now)
        }
        doneGroups.sort { a, b in
            let pa = Self.priorityOrder(a[0].item.itemPriority)
            let pb = Self.priorityOrder(b[0].item.itemPriority)
            if pa != pb { return pa < pb }
            return Self.sortAnchor(for: a[0], now: now) < Self.sortAnchor(for: b[0], now: now)
        }
        return (pendingGroups + doneGroups).flatMap { $0 }
    }

    /// 그룹의 대표 row — 첫 pending occurrence, 없으면 첫 row.
    private static func pendingRepresentative(of group: [OccurrenceRow]) -> OccurrenceRow {
        group.first { !$0.item.isCompletedForDate($0.occurrenceDate) } ?? group[0]
    }

    /// priority 정렬 키 — high(0) → medium(1) → low(2) → none(3).
    private static func priorityOrder(_ p: Priority) -> Int {
        switch p {
        case .high:   return 0
        case .medium: return 1
        case .low:    return 2
        case .none:   return 3
        }
    }

    /// sort anchor — 위젯과 동일한 정책.
    /// - 진행 중/지남: 종료 instant (없으면 시작+24h)
    /// - 예정: 시작 instant
    /// - 시간 없음: 시작+24h (시간 있는 항목 뒤로)
    private static func sortAnchor(for row: OccurrenceRow, now: Date) -> TimeInterval {
        let item = row.item
        let occ = row.occurrenceDate
        guard let start = Item.localInstant(fromCalendarDate: occ, hour: item.startHourInt) else { return 0 }
        let span = item.spanDays
        let endDay = Calendar.gmt.date(byAdding: .day, value: span, to: occ) ?? occ
        let end = Item.localInstant(fromCalendarDate: endDay, hour: item.dueHourInt)
        if !item.hasExplicitTime {
            return start.addingTimeInterval(24 * 3600).timeIntervalSince1970
        }
        if now < start {
            return start.timeIntervalSince1970
        }
        if let end = end, now >= end {
            return end.timeIntervalSince1970
        }
        return (end ?? start).timeIntervalSince1970
    }

    /// Item 단위 그룹 — 같은 Item의 연속 occurrence를 한 group으로 묶음.
    /// rows는 같은 Item의 occurrence가 인접한 순서로 정렬돼 있다고 가정 (sortedRoutines/ntdsForDate).
    /// 각 group은 List row 1개로 렌더링됨 → List의 enforced row 높이 영향에서 자유로움.
    struct ItemGroup: Identifiable {
        let item: Item
        let occurrences: [OccurrenceRow]
        var id: NSManagedObjectID { item.objectID }
    }

    private func itemGroups(_ rows: [OccurrenceRow]) -> [ItemGroup] {
        var result: [ItemGroup] = []
        var currentItem: Item? = nil
        var currentOccs: [OccurrenceRow] = []
        for row in rows {
            if currentItem?.objectID == row.item.objectID {
                currentOccs.append(row)
            } else {
                if let item = currentItem {
                    result.append(ItemGroup(item: item, occurrences: currentOccs))
                }
                currentItem = row.item
                currentOccs = [row]
            }
        }
        if let item = currentItem {
            result.append(ItemGroup(item: item, occurrences: currentOccs))
        }
        return result
    }

    /// 통합 fetch를 시간 instant 기반으로 시작/진행/마감 섹션에 그룹화한 결과.
    /// body에서 한 번만 계산 — `now`를 body 내에서 생성·전달.
    private func grouped(now: Date) -> [TodoTodaySection: [Item]] {
        var groups: [TodoTodaySection: [Item]] = [.start: [], .inProgress: [], .due: []]
        for item in allActiveTodos where matchesCategoryFilter(item) {
            guard let section = item.todoSection(on: date, now: now) else { continue }
            groups[section, default: []].append(item)
        }
        return groups
    }

    /// 활성 카테고리 — categoryFilter prop으로 lookup. nil이면 미적용.
    private var activeCategory: Category? {
        guard let id = categoryFilter else { return nil }
        return categories.first(where: { $0.id == id })
    }

    /// section header — 평소엔 title text. 카테고리 필터 활성 시 title 바로 옆에
    /// 카테고리 색 filled circle + white symbol (CategoryListView와 동일 스타일).
    @ViewBuilder
    private func sectionHeader(_ titleKey: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Text(titleKey)
            if let cat = activeCategory {
                let color: Color = {
                    guard let raw = cat.colorHex, let cc = CategoryColor(rawValue: raw) else {
                        return Color.accentColor
                    }
                    return cc.color
                }()
                Image(systemName: cat.iconName ?? CategoryIcon.defaultIcon.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(color))
            }
        }
    }

    var body: some View {
        // 2-섹션 모델: NTD / 할일(1회성+루틴 통합).
        // 할일 섹션: pending 그룹 먼저 → done 그룹 끝, 같은 bucket 내 priority desc → 시간 가까운 순.
        let activitiesSorted = displayActivities()
        List {
            Section {
                if ntdsForDate.isEmpty {
                    emptyRow("today.empty.not_todo")
                } else {
                    // 그룹 = List row 1개. 내부 VStack 간격으로 occurrence 간 간격 직접 제어 (List 강제 높이 회피).
                    ForEach(itemGroups(ntdsForDate)) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(group.occurrences.enumerated()), id: \.element.id) { idx, occ in
                                let isLast = (idx == group.occurrences.count - 1)
                                Button {
                                    // 취소 모드에서는 편집 sheet 차단 — (x) 버튼 액션만 활성.
                                    guard !cancelMode else { return }
                                    sheet = .edit(group.item)
                                } label: {
                                    NTDRow(
                                        item: group.item,
                                        occurrenceDate: occ.occurrenceDate,
                                        compactMode: !isLast
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            } header: {
                sectionHeader("today.section.not_todo")
            }

            Section {
                if activitiesSorted.isEmpty {
                    emptyRow("today.empty.todo")
                } else {
                    ForEach(itemGroups(activitiesSorted)) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(group.occurrences.enumerated()), id: \.element.id) { idx, occ in
                                let isLast = (idx == group.occurrences.count - 1)
                                // 1회성은 occurrence 1개 (group 첫 row=마지막=last). 루틴은 multi 가능.
                                rowButton(
                                    for: group.item,
                                    occurrenceStart: group.item.recurrenceRule != nil ? occ.occurrenceDate : nil,
                                    compact: !isLast
                                )
                            }
                        }
                    }
                }
            } header: {
                sectionHeader("today.section.todo")
            }
        }
        .listStyle(.insetGrouped)
        // 하단 (+) FAB(56pt + padding 20pt)에 마지막 row가 가리지 않도록 스크롤 여백 확보.
        .contentMargins(.bottom, 96, for: .scrollContent)
        // 첫 render 후 할일(1회성+루틴) 정렬 snapshot 캡처 — 이후 체크/취소 토글로 인한 reorder 회피.
        // date 변경 시 부모 .id(displayedDate)로 view 재생성 → @State 초기화 → 다시 캡처.
        .onAppear {
            if stableActivityOrder.isEmpty {
                stableActivityOrder = sortedActivities().map { $0.id }
            }
        }
    }

    /// occurrenceStart override + compact mode 전달.
    /// compact=true면 ItemRow가 아이콘+제목+d-day만 노출 (그룹 마지막 외 row용).
    private func rowButton(for item: Item, occurrenceStart: Date? = nil, compact: Bool = false) -> some View {
        Button {
            // 취소 모드에서는 편집 sheet 차단 — (x) 버튼 액션만 활성.
            guard !cancelMode else { return }
            sheet = .edit(item)
        } label: {
            ItemRow(
                item: item,
                referenceDate: date,
                occurrenceStartOverride: occurrenceStart,
                compactMode: compact
            )
        }
        .buttonStyle(.plain)
    }

    private func emptyRow(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .foregroundStyle(.secondary)
            .font(.subheadline)
    }
}

#Preview {
    NavigationStack { TodayView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
