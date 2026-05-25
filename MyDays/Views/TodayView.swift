import CoreData
import SwiftUI

struct TodayView: View {

    // displayedDate는 calendar date 의미 → UTC anchor Date로 관리.
    // 화살표/jump 동작도 모두 UTC 캘린더로 일관성 유지.
    @State private var displayedDate: Date = .todayCalendarAnchor
    // 자정 넘김 감지 기준값. 변경 감지 후 displayedDate를 ±1 범위에서 자동 shift.
    @State private var lastKnownToday: Date = .todayCalendarAnchor
    @State private var sheet: ItemSheetMode?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TodayList(date: displayedDate, sheet: $sheet)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { shiftDay(-1) } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                if isFarFuture {
                    if #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .topBarLeading)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: jumpToToday) {
                            Text("nav.jump_home")
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(navigationTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize()
                }
                if isFarPast {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: jumpToToday) {
                            Text("nav.jump_home")
                        }
                    }
                    if #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { shiftDay(1) } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    sheet = .new(baseDate: displayedDate)
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
            .sheet(item: $sheet) { mode in
                switch mode {
                case .new(let baseDate):
                    AddItemView(baseDate: baseDate)
                case .edit(let item):
                    AddItemView(editing: item)
                }
            }
            // 자정 넘김 시 — Foreground 중이면 NSCalendarDayChanged fire,
            // 백그라운드에서 자정 통과 후 복귀하면 scenePhase==.active로 잡음.
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                handleDayChange()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { handleDayChange() }
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
        // displayedDate(UTC anchor)에 UTC 캘린더로 ±1일.
        if let next = Calendar.gmt.date(byAdding: .day, value: value, to: displayedDate) {
            displayedDate = next
        }
    }

    private func jumpToToday() {
        displayedDate = .todayCalendarAnchor
    }

    private var daysFromToday: Int {
        // 둘 다 UTC anchor → UTC 캘린더로 일수 차 계산.
        let today: Date = .todayCalendarAnchor
        return Calendar.gmt.dateComponents([.day], from: today, to: displayedDate).day ?? 0
    }

    private var isFarPast: Bool { daysFromToday < -1 }
    private var isFarFuture: Bool { daysFromToday > 1 }

    private var navigationTitle: String {
        // 모든 케이스에 "(요일)" 일관 표시 — 어제/오늘/내일·임의 날짜 동일 포맷.
        // UTC anchor displayedDate → formatter도 UTC로 해석.
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale.current
        weekdayFormatter.timeZone = utc
        weekdayFormatter.setLocalizedDateFormatFromTemplate("EEE")
        let weekday = weekdayFormatter.string(from: displayedDate)

        let base: String
        switch daysFromToday {
        case 0:  base = String(localized: "today.nav.today")
        case 1:  base = String(localized: "today.nav.tomorrow")
        case -1: base = String(localized: "today.nav.yesterday")
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.timeZone = utc
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            base = formatter.string(from: displayedDate)
        }
        return "\(base) (\(weekday))"
    }
}

struct TodayList: View {

    let date: Date
    @Binding var sheet: ItemSheetMode?

    /// 통합 fetch — displayedDay가 [startDate, dueDate] 구간 안에 있는 모든 active 1회성 Todo.
    /// 시작·진행·마감 섹션 분류는 view-side `classify(_:now:)`에서 시간 instant 기반으로 동적.
    @FetchRequest var allActiveTodos: FetchedResults<Item>
    @FetchRequest var routineItems: FetchedResults<Item>
    @FetchRequest var ntdItems: FetchedResults<Item>

    init(date: Date, sheet: Binding<ItemSheetMode?>) {
        self.date = date
        self._sheet = sheet
        // date는 UTC anchor. FetchRequest predicate의 [start, end) 범위도 UTC 자정 기준으로 계산해
        // 저장된 startDate/dueDate(UTC anchor)와 정확히 비교되도록 한다.
        let start = Calendar.gmt.startOfDay(for: date)
        let end = Calendar.gmt.date(byAdding: .day, value: 1, to: start) ?? start
        let sort = [SortDescriptor(\Item.priority, order: .reverse), SortDescriptor(\Item.createdAt)]

        // displayedDay가 [startDate, dueDate] 구간 안에 있는 1회성:
        //   (startDate == nil OR startDate < end) AND (dueDate == nil OR dueDate >= start)
        // status != 2 — pending(0) + done(1) + failed(3) 모두 포함. 완료 항목도 그날 화면에 잔류 표시.
        _allActiveTodos = FetchRequest(
            sortDescriptors: sort,
            predicate: NSPredicate(
                format: "status != 2 AND recurrenceRule == nil AND kind == 0 AND isSomeday == NO "
                      + "AND (startDate == nil OR startDate < %@) "
                      + "AND (dueDate == nil OR dueDate >= %@)",
                end as NSDate, start as NSDate
            ),
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

    /// displayedDate에 표시할 NTD occurrence 목록.
    ///
    /// 원칙 (사용자 정의):
    ///   - displayedDate가 occurrence의 노출 범위 [start ~ end] 안에 있으면 표시
    ///     · end = duration 설정됨: 계획된 종료 instant의 local 일자
    ///     · end = duration 없음 + RC/Item.completedAt: 그 instant의 local 일자
    ///     · end = duration 없음 + 진행 중: now의 local 일자 (현재까지 진행시간)
    ///   - 완료/포기 occurrence도 노출 범위 안에 있는 한 표시 (NTDRow가 상태 라벨 처리)
    /// 한 Item당 한 occurrence만 노출 (가장 먼저 매치된 것).
    private var ntdsForDate: [(item: Item, occurrenceDate: Date)] {
        let now = Date()
        var result: [(Item, Date)] = []

        for item in ntdItems {
            let candidates = item.ntdOccurrenceStartCandidates(coveringDate: date)
            for occDate in candidates {
                let range = item.ntdOccurrenceCalendarRange(occurrenceDate: occDate, now: now)
                if range.start <= date && date <= range.end {
                    result.append((item, occDate))
                    break
                }
            }
        }
        return result
    }

    private var routinesForDate: [Item] {
        let target = date
        return routineItems.filter { item in
            // multi-day occurrence(start~start+span)의 어떤 위치에라도 걸리면 노출.
            // 단일 day occurrence는 span=0이라 occurrencePosition이 .start만 반환.
            return item.occurrencePosition(on: target) != nil
        }
    }

    /// 통합 fetch를 시간 instant 기반으로 시작/진행/마감 섹션에 그룹화한 결과.
    /// body에서 한 번만 계산 — `now`를 body 내에서 생성·전달.
    private func grouped(now: Date) -> [TodoTodaySection: [Item]] {
        var groups: [TodoTodaySection: [Item]] = [.start: [], .inProgress: [], .due: []]
        for item in allActiveTodos {
            guard let section = item.todoSection(on: date, now: now) else { continue }
            groups[section, default: []].append(item)
        }
        return groups
    }

    var body: some View {
        // body 한 render 동안 동일 now 사용 — 분류 안정성 확보.
        let now = Date()
        let groups = grouped(now: now)
        // 3-섹션 모델: NTD / 할일 / 루틴. 할일 섹션은 시작·진행 중·마감 모두 통합 노출.
        // 순서: 미완료 항목(.start → .inProgress → .due) 먼저, 완료 항목은 섹션 끝으로.
        let todoGroupRaw = (groups[.start] ?? []) + (groups[.inProgress] ?? []) + (groups[.due] ?? [])
        let pendingTodos = todoGroupRaw.filter { $0.itemStatus == .pending }
        let doneTodos = todoGroupRaw.filter { $0.itemStatus != .pending }
        let todoGroup = pendingTodos + doneTodos
        // 루틴 섹션: 그 날짜에 완료된 occurrence는 섹션 끝으로.
        let routinesRaw = routinesForDate
        let pendingRoutines = routinesRaw.filter { !$0.isCompletedForDate(date) }
        let doneRoutines = routinesRaw.filter { $0.isCompletedForDate(date) }
        let routinesSorted = pendingRoutines + doneRoutines
        List {
            Section("today.section.not_todo") {
                if ntdsForDate.isEmpty {
                    emptyRow("today.empty.not_todo")
                } else {
                    ForEach(ntdsForDate, id: \.item.objectID) { pair in
                        Button {
                            sheet = .edit(pair.item)
                        } label: {
                            NTDRow(item: pair.item, occurrenceDate: pair.occurrenceDate)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("today.section.todo") {
                if todoGroup.isEmpty {
                    emptyRow("today.empty.todo")
                } else {
                    ForEach(todoGroup, id: \.objectID) { rowButton(for: $0) }
                }
            }

            Section("today.section.routine") {
                if routinesSorted.isEmpty {
                    emptyRow("today.empty.routine")
                } else {
                    ForEach(routinesSorted, id: \.objectID) { rowButton(for: $0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        // 하단 (+) FAB(56pt + padding 20pt)에 마지막 row가 가리지 않도록 스크롤 여백 확보.
        .contentMargins(.bottom, 96, for: .scrollContent)
    }

    private func rowButton(for item: Item) -> some View {
        Button {
            sheet = .edit(item)
        } label: {
            ItemRow(item: item, referenceDate: date)
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
