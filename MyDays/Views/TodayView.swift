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
    // 앱 종료 후 재실행 시 마지막 선택 모드 복원 (@AppStorage).
    @AppStorage(UIStateKey.todayViewMode) private var viewMode: TodayViewMode = .day
    // 특정일 이동 시트.
    @State private var showDatePicker: Bool = false
    @State private var datePickerSelection: Date = Date()
    // 카테고리 필터 — nil이면 "모두". ListView와 동일 패턴.
    @State private var filterCategoryID: UUID?
    /// 목표 유형 필터 — nil이면 무관. 단일 필터 정책 (카테고리와 상호 배타).
    @State private var filterGoalKind: ItemKind?
    // 완료/포기 항목 표시 — true=전체, false=미완료만. 오늘은 default true (오늘 완료한 것도 보임).
    // 앱 재실행 시 마지막 토글 상태 복원.
    @AppStorage(UIStateKey.todayShowCompleted) private var showCompleted: Bool = true
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
            TodayList(date: displayedDate,
                      categoryFilter: filterCategoryID,
                      goalKindFilter: filterGoalKind,
                      showCompleted: showCompleted,
                      sheet: $sheet)
                .id(displayedDate)
                .transition(.asymmetric(
                    insertion: .move(edge: insertionEdge),
                    removal: .move(edge: removalEdge)
                ))
        }
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
        // 주의: `.clipped()`는 ZStack 위에 두지 말 것 — iOS 26 TabView가 scroll content edge를
        // 감지 못해 floating 탭바가 opaque로 fallback됨 (다른 탭은 반투명). transition overflow는
        // safeAreaInset 경계로 자연스럽게 잘림.
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
                        categoryFilter: filterCategoryID,
                        goalKindFilter: filterGoalKind
                    )
                }
            }
            // 외곽 ZStack `.clipped()`를 제거해 floating 탭바 반투명을 복원하면서 safeAreaInset의
            // 암묵 backdrop도 사라짐 → List 본문이 inset 영역에 비침. 명시 systemBackground로 차단.
            .background(Color(.systemBackground))
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
                    Button {
                        showCompleted.toggle()
                    } label: {
                        // ListView/ArchiveView와 동일 — filled=전체 보임, unchecked=미완료만.
                        Image(systemName: showCompleted ? "checklist" : "checklist.unchecked")
                    }
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
        //   - 기존 개별 버튼 UI(원형 chevron + 캡슐 오늘) 유지
        //   - 그 위로 단일 반투명 capsule(.thinMaterial)을 outer wrapper로 추가 — 버튼 사이 빈 영역으로
        //     List row 탭이 통과되는 leak 차단 (outer surface가 탭 흡수)
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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                // 라이트 모드에선 Form 배경(systemGroupedBackground)과 톤이 비슷해
                // 단순 material만으론 경계가 흐림 → regularMaterial로 saturation 올리고
                // 미세 stroke로 윤곽 강조 (다크 모드에서도 자연스러움).
                .background(
                    Capsule()
                        .fill(.regularMaterial)
                        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                )
                .padding(20)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // 새 항목 추가 FAB — 취소 모드 중에는 숨김.
            if !cancelMode {
                Button {
                    // 필터 활성 시 신규 항목에 preset — 카테고리(Todo) 또는 목표 유형.
                    sheet = .new(baseDate: displayedDate, categoryID: filterCategoryID, goalKind: filterGoalKind)
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
                case .new(let baseDate, let categoryID, let goalKind):
                    AddItemView(baseDate: baseDate, categoryID: categoryID, goalKind: goalKind)
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
                .appTint()
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
            // ⌘N 단축키 — RootView가 currentTab과 함께 broadcast. .today일 때만 새 항목 열기.
            .onReceive(NotificationCenter.default.publisher(for: .openNewItemForCurrentTab)) { note in
                guard (note.object as? SidebarItem) == .today else { return }
                sheet = .new(baseDate: displayedDate, categoryID: filterCategoryID, goalKind: filterGoalKind)
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

    /// 통합 필터 Menu — "모두" + 카테고리 section + 목표 유형 section.
    /// 단일 필터 정책: 카테고리 선택 시 goalKind 자동 nil, 목표 유형 선택 시 categoryID 자동 nil.
    /// 활성 시 아이콘 filled.
    @ViewBuilder
    private var categoryFilterMenu: some View {
        Menu {
            Button {
                filterCategoryID = nil
                filterGoalKind = nil
            } label: {
                if filterCategoryID == nil && filterGoalKind == nil {
                    Label("list.filter.all", systemImage: "checkmark")
                } else {
                    Text("list.filter.all")
                }
            }
            // 카테고리 section (Todo 분류) — divider만, title 없음.
            if !categories.isEmpty {
                Section {
                    ForEach(categories, id: \.id) { cat in
                        Button {
                            filterCategoryID = cat.id
                            filterGoalKind = nil
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
                }
            }
            // 목표 유형 section — divider만.
            Section {
                ForEach(Self.goalKindFilterOrder, id: \.self) { kind in
                    Button {
                        filterGoalKind = kind
                        filterCategoryID = nil
                    } label: {
                        if filterGoalKind == kind {
                            Label(kind.displayName, systemImage: "checkmark")
                        } else {
                            Label {
                                Text(verbatim: kind.displayName)
                            } icon: {
                                Image(systemName: kind.goalTypeSymbolName)
                            }
                        }
                    }
                }
            }
        } label: {
            let active = filterCategoryID != nil || filterGoalKind != nil
            Image(systemName: active
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
    }

    /// 목표 유형 필터 옵션 순서 — sub-picker와 동일.
    private static let goalKindFilterOrder: [ItemKind] = [.notTodo, .activity, .focus, .habit]

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
enum TodayViewMode: String { case day, month }

struct TodayList: View {

    let date: Date
    /// 카테고리 필터 — nil이면 "모두". 매 fetch 결과를 view-side filter (ListView와 동일 패턴).
    let categoryFilter: UUID?
    /// 목표 유형 필터 — nil이면 무관. 단일 필터 정책상 categoryFilter와 동시 활성 불가.
    let goalKindFilter: ItemKind?
    /// 완료(done)/포기(failed) 항목 표시 여부. false면 NTD/Todo/Routine 공통으로 finished 항목 숨김.
    let showCompleted: Bool
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

    init(date: Date, categoryFilter: UUID?, goalKindFilter: ItemKind?, showCompleted: Bool, sheet: Binding<ItemSheetMode?>) {
        self.date = date
        self.categoryFilter = categoryFilter
        self.goalKindFilter = goalKindFilter
        self.showCompleted = showCompleted
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
        // 할일 섹션 = kind == 0 (Todo). 습관(kind=4)은 목표 섹션으로 이동.
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
        // 목표 섹션 후보: 삭제(2)되지 않은 목표 항목(절제·활동·습관 — Phase A+B. 집중은 Phase D).
        // status 1(done)·3(failed)인 1회성도 "오늘 종료된 것"은 그날 화면에 남김.
        // 1회성/반복 + 모든 목표 type 통합 fetch — 분기는 view-side에서.
        _ntdItems = FetchRequest(
            sortDescriptors: [SortDescriptor(\Item.createdAt)],
            // 목표 4-type 통합 fetch: NTD(1) + activity(2) + focus(3) + habit(4). status != deleted.
            predicate: NSPredicate(format: "(kind == 1 OR kind == 2 OR kind == 3 OR kind == 4) AND status != 2"),
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
    /// 통합 필터 — 단일 필터 정책. 카테고리 또는 목표 유형 중 하나만 활성 (둘 다 nil이면 전체 통과).
    /// - 카테고리 선택: Todo + category 매칭만. 목표 모두 hide.
    /// - 목표 유형 선택: 그 type만. Todo + 다른 목표 type 모두 hide.
    private func matchesCategoryFilter(_ item: Item) -> Bool {
        if let id = categoryFilter {
            return item.itemKind == .todo && item.category?.id == id
        }
        if let goalKind = goalKindFilter {
            return item.itemKind == goalKind
        }
        return true
    }

    /// occurrence가 "끝난" 상태인지 — 완료(done) or 포기(failed).
    /// - 1회성: Item.itemStatus == .done OR .failed
    /// - 반복: 해당 occurrenceDate의 RoutineCompletion 중 done OR failed 1개 이상
    /// showCompleted=false일 때 NTD/Todo/Routine 공통으로 finished 항목 숨김.
    private func isFinishedOccurrence(item: Item, occurrenceDate: Date) -> Bool {
        if item.recurrenceRule == nil {
            return item.itemStatus == .done || item.itemStatus == .failed
        }
        let day = Calendar.gmt.startOfDay(for: occurrenceDate)
        let completions = (item.completions as? Set<RoutineCompletion>) ?? []
        return completions.contains { c in
            guard let d = c.date else { return false }
            guard Calendar.gmt.isDate(d, inSameDayAs: day) else { return false }
            return c.done || c.failed
        }
    }

    /// 목표 섹션 표시 행 (Phase A: 절제 NTD + 습관).
    ///
    /// **NTD** — 같은 NTD가 여러 occurrence와 겹쳐도 단일 행만 노출.
    /// - 오늘: inProgress > scheduled(가장 빠른) > ended(가장 최근)
    /// - 비-오늘: 해당 일자에 **시작**하는 occurrence만
    ///
    /// **습관** — routine Todo와 동일 occurrence 로직.
    /// - 반복: rule.occurs(on: date) 매칭 시 1행
    /// - 1회성: startDate == date 매칭 시 1행
    ///
    /// **정렬**: 미완료 우선 (NTD inProgress → NTD scheduled → habit pending) → 완료/포기 끝.
    private var ntdsForDate: [OccurrenceRow] {
        let now = Date()
        let isToday = date == .todayCalendarAnchor
        var result: [OccurrenceRow] = []

        for item in ntdItems where matchesCategoryFilter(item) {
            switch item.itemKind {
            case .notTodo:
                if let row = ntdOccurrenceRow(for: item, isToday: isToday, now: now) {
                    result.append(row)
                }
            case .habit, .activity, .focus:
                // 활동·집중도 habit과 동일 occurrence 로직 (rule.occurs / startDate 매칭). 종일 의미.
                if let row = habitOccurrenceRow(for: item) {
                    result.append(row)
                }
            default:
                continue
            }
        }
        return result.sorted { lhs, rhs in
            let lp = goalSortPriority(row: lhs, now: now)
            let rp = goalSortPriority(row: rhs, now: now)
            if lp.bucket != rp.bucket { return lp.bucket < rp.bucket }
            if lp.timeAnchor != rp.timeAnchor { return lp.timeAnchor < rp.timeAnchor }
            return (lhs.item.createdAt ?? .distantPast) < (rhs.item.createdAt ?? .distantPast)
        }
    }

    /// 목표 섹션 정렬 키.
    /// bucket: 0=미완료(NTD inProgress, NTD scheduled, habit pending) — 1=완료/포기.
    /// timeAnchor: bucket 안 정렬 — NTD는 시각 instant, habit은 .distantFuture(같은 group 끝).
    private func goalSortPriority(row: OccurrenceRow, now: Date) -> (bucket: Int, timeAnchor: TimeInterval) {
        let item = row.item
        let finished = isFinishedOccurrence(item: item, occurrenceDate: row.occurrenceDate)
        if finished {
            // 완료/포기 항목은 끝에. 같은 그룹 내 completedAt 최신 먼저 (negative anchor).
            let inst = item.routineRecord(on: row.occurrenceDate)?.completedAt
                ?? item.completedAt
                ?? .distantPast
            return (1, -inst.timeIntervalSince1970)
        }
        // 미완료 — NTD는 시각 anchor(inProgress=현재 종료, scheduled=시작), habit은 anchor 없음.
        switch item.itemKind {
        case .notTodo:
            if let state = item.ntdState(on: row.occurrenceDate, now: now) {
                switch state {
                case .inProgress:
                    let end = item.ntdEndInstant(on: row.occurrenceDate) ?? .distantFuture
                    return (0, end.timeIntervalSince1970)  // 종료 가까운 순
                case .scheduled:
                    let start = item.ntdStartInstant(on: row.occurrenceDate) ?? .distantFuture
                    // scheduled는 inProgress보다 뒤 (큰 timeAnchor).
                    return (0, start.timeIntervalSince1970 + 1_000_000_000)
                case .ended:
                    // ended(자동 완료 대기 — fetch에 남아있는 케이스)
                    return (0, .greatestFiniteMagnitude)
                }
            }
            return (0, .greatestFiniteMagnitude)
        case .habit, .activity, .focus:
            // habit·activity·focus pending — NTD scheduled보다 뒤로 (더 큰 anchor).
            // 셋 다 종일 의미라 시각 anchor 없음 → createdAt fallback에 위임.
            return (0, .greatestFiniteMagnitude - 1)
        default:
            return (0, .greatestFiniteMagnitude)
        }
    }

    /// NTD 단일 occurrence 행 생성 — 후보 필터 + 우선순위 선택.
    private func ntdOccurrenceRow(for item: Item, isToday: Bool, now: Date) -> OccurrenceRow? {
        let candidates = item.ntdOccurrenceStartCandidates(coveringDate: date)
        var occurrences: [Date] = []
        for occDate in candidates {
            let range = item.ntdOccurrenceCalendarRange(occurrenceDate: occDate, now: now)
            guard range.start <= date && date <= range.end else { continue }
            if !showCompleted, isFinishedOccurrence(item: item, occurrenceDate: occDate) { continue }
            occurrences.append(occDate)
        }
        guard !occurrences.isEmpty else { return nil }
        let selected: Date? = isToday
            ? selectSingleNTDOccurrence(item: item, occurrences: occurrences, now: now)
            : occurrences.first { $0 == date }
        guard let selected else { return nil }
        return OccurrenceRow(item: item, occurrenceDate: selected)
    }

    /// 습관 occurrence 행 생성 — 1회성/반복 단순 매칭.
    private func habitOccurrenceRow(for item: Item) -> OccurrenceRow? {
        if let rule = item.recurrenceRule {
            guard rule.occurs(on: date, startDate: item.startDate, endDate: item.recurrenceEndDate) else { return nil }
        } else {
            // 1회성 습관: startDate가 view date와 일치할 때만.
            guard let s = item.startDate, s == date else { return nil }
        }
        if !showCompleted, isFinishedOccurrence(item: item, occurrenceDate: date) { return nil }
        return OccurrenceRow(item: item, occurrenceDate: date)
    }

    /// 오늘 모드 — 같은 NTD의 다중 occurrence 중 하나만 선택.
    /// inProgress > scheduled(가장 빠른) > ended(가장 최근).
    /// 각 occurrence의 state를 한 번만 계산해 cache (loop 안 중복 호출 회피).
    ///
    /// **중요**: ntdState는 시간 기반 — 시간상 .inProgress여도 실제 포기/완료된 occurrence는
    /// 다음 occurrence가 표시되도록 inProgress/scheduled 후보에서 제외.
    /// 예: 어제 20시 시작 16h 단식 → 22시 포기 → 시간상 어제 occurrence는 여전히 .inProgress (종료 12시까지)
    /// → 필터 안 하면 포기된 어제가 우선 선택돼서 오늘 scheduled occurrence가 안 보임.
    private func selectSingleNTDOccurrence(item: Item, occurrences: [Date], now: Date) -> Date {
        let states: [(date: Date, state: Item.NTDState?, finished: Bool)] = occurrences.map { occDate in
            (occDate, item.ntdState(on: occDate, now: now), isFinishedOccurrence(item: item, occurrenceDate: occDate))
        }
        // 미완료 진행 중 우선.
        if let inProgress = states.first(where: { $0.state == .inProgress && !$0.finished })?.date {
            return inProgress
        }
        // 미완료 scheduled 중 가장 빠른 시작.
        let scheduled = states.filter { $0.state == .scheduled && !$0.finished }.map(\.date)
        if let earliest = scheduled.min(by: { a, b in
            let aStart = item.ntdStartInstant(on: a) ?? .distantFuture
            let bStart = item.ntdStartInstant(on: b) ?? .distantFuture
            return aStart < bStart
        }) {
            return earliest
        }
        // 그 외 (전부 finished 등) — 가장 최근 occurrence fallback.
        if let mostRecent = occurrences.max(by: { a, b in
            let aStart = item.ntdStartInstant(on: a) ?? .distantPast
            let bStart = item.ntdStartInstant(on: b) ?? .distantPast
            return aStart < bStart
        }) {
            return mostRecent
        }
        return occurrences[0]
    }

    /// 반복 항목 occurrence 목록. multi-day 겹침 시 같은 Item의 여러 occurrence 모두 반환.
    /// `Item.occurrenceStartsCovering(date:)`로 cover하는 모든 start dates 수집.
    private var routinesForDate: [OccurrenceRow] {
        var result: [OccurrenceRow] = []
        for item in routineItems where matchesCategoryFilter(item) {
            for start in item.occurrenceStartsCovering(date: date) {
                if !showCompleted, isFinishedOccurrence(item: item, occurrenceDate: start) { continue }
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
            if !showCompleted, isFinishedOccurrence(item: item, occurrenceDate: item.startDate ?? date) { continue }
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

    /// 섹션 정체성 — Todo 섹션은 카테고리 필터 아이콘, Goal 섹션은 목표 유형 필터 아이콘.
    enum SectionScope { case todo, goal }

    /// section header.
    /// 필터 미활성: 기본 title text ("목표" / "할일").
    /// 필터 활성: ListView 패턴 — `(아이콘) 카테고리명` 또는 `(아이콘) 목표유형명` 만 표시.
    @ViewBuilder
    private func sectionHeader(_ titleKey: LocalizedStringKey, scope: SectionScope) -> some View {
        switch scope {
        case .todo:
            if let cat = activeCategory {
                HStack(spacing: 8) {
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
                    Text(verbatim: cat.name ?? "")
                }
            } else {
                Text(titleKey)
            }
        case .goal:
            if let kind = goalKindFilter {
                HStack(spacing: 8) {
                    Image(systemName: kind.goalTypeSymbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.accentColor))
                    Text(verbatim: kind.displayName)
                }
            } else {
                Text(titleKey)
            }
        }
    }

    var body: some View {
        // 2-섹션 모델: NTD / 할일(1회성+루틴 통합).
        // 단일 필터 정책 — 카테고리 선택 시 목표 섹션 hide, 목표 유형 선택 시 할일 섹션 hide.
        let activitiesSorted = displayActivities()
        let showGoalSection = categoryFilter == nil  // 카테고리 필터엔 목표 hide
        let showTodoSection = goalKindFilter == nil  // 목표 유형 필터엔 할일 hide
        List {
            if showGoalSection {
                Section {
                    if ntdsForDate.isEmpty {
                        emptyRow("today.empty.not_todo")
                    } else {
                        // 그룹 = List row 1개. 내부 VStack 간격으로 occurrence 간 간격 직접 제어 (List 강제 높이 회피).
                        // NTD(절제)는 NTDRow, 습관은 ItemRow로 렌더 — type별 정체성 유지.
                        ForEach(itemGroups(ntdsForDate)) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(group.occurrences.enumerated()), id: \.element.id) { idx, occ in
                                    let isLast = (idx == group.occurrences.count - 1)
                                    Button {
                                        guard !cancelMode else { return }
                                        sheet = .edit(group.item)
                                    } label: {
                                        goalRow(item: group.item, occurrenceDate: occ.occurrenceDate, isLast: isLast)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } header: {
                    sectionHeader("today.section.not_todo", scope: .goal)
                }
            }

            if showTodoSection {
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
                    sectionHeader("today.section.todo", scope: .todo)
                }
            }
        }
        .listStyle(.insetGrouped)
        // iPad/regular size class에서 content 폭 cap — 가독성.
        .iPadContentWidth()
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

    /// 목표 섹션 row — type별 row component 분기.
    /// - 절제(.notTodo): NTDRow (카운트다운·progress capsule·(x) 포기)
    /// - 습관(.habit)·활동(.activity)·집중(.focus): ItemRow (goalLeadingIcon + 각자 trailing UI)
    @ViewBuilder
    private func goalRow(item: Item, occurrenceDate: Date, isLast: Bool) -> some View {
        switch item.itemKind {
        case .notTodo:
            NTDRow(item: item, occurrenceDate: occurrenceDate, displayedDate: date, compactMode: !isLast)
        case .habit, .activity, .focus:
            // routine은 occurrenceDate 기준 RC. 1회성은 startDate 기준 (canonical).
            // trailing UI는 ItemRow 안에서 type별 분기 (habit=체크, activity=progress+N, focus=progress+▶).
            ItemRow(
                item: item,
                referenceDate: date,
                occurrenceStartOverride: item.recurrenceRule != nil ? occurrenceDate : nil,
                compactMode: !isLast
            )
        default:
            // 집중(.focus) Phase D — 현재 fetch에서 제외돼 도달 X.
            EmptyView()
        }
    }
}

#Preview {
    NavigationStack { TodayView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
