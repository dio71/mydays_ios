import CoreData
import SwiftUI

struct TodayView: View {

    // displayedDate는 calendar date 의미 → UTC anchor Date로 관리.
    // 화살표/jump 동작도 모두 UTC 캘린더로 일관성 유지.
    @State private var displayedDate: Date = .todayCalendarAnchor
    // 자정 넘김 감지 기준값. 변경 감지 후 displayedDate를 ±1 범위에서 자동 shift.
    @State private var lastKnownToday: Date = .todayCalendarAnchor
    @State private var sheet: ItemSheetMode?
    // 일자 이동 방향 — slide 애니메이션 방향 제어. forward(미래) → 새 view가 우측에서 진입.
    @State private var lastNavigationForward: Bool = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // ZStack + .id로 view identity 변경 시 transition 발동.
        // 외곽 ZStack에 .animation 부착 — implicit하게 insertion/removal animate.
        // toolbar는 ZStack 외부에 둠 — view 재생성 시 toolbar 깜빡임 방지.
        let insertionEdge: Edge = lastNavigationForward ? .trailing : .leading
        let removalEdge: Edge = lastNavigationForward ? .leading : .trailing
        ZStack {
            TodayList(date: displayedDate, sheet: $sheet)
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
                    let h = value.translation.width
                    let v = value.translation.height
                    guard abs(h) > abs(v) * 2, abs(h) > 60 else { return }
                    // 오른쪽 스와이프 → 이전 일자, 왼쪽 스와이프 → 다음 일자.
                    shiftDay(h > 0 ? -1 : 1)
                }
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { shiftDay(-1) } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            ToolbarItem(placement: .principal) {
                Text(navigationTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { shiftDay(1) } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        // 하단 leading: "오늘" 버튼 항상 노출. 색상으로 상태 표시:
        //   - 오늘: accent fill + 흰 글자 (현재 위치 indicator)
        //   - 다른 날: gray fill + secondary 글자 (탭하면 jump)
        .overlay(alignment: .bottomLeading) {
            let isToday = daysFromToday == 0
            Button(action: jumpToToday) {
                Text("nav.jump_home")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isToday ? .white : Color.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(isToday ? Color.accentColor : Color(.systemGray4)))
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            }
            .padding(20)
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

    private var daysFromToday: Int {
        // 둘 다 UTC anchor → UTC 캘린더로 일수 차 계산.
        let today: Date = .todayCalendarAnchor
        return Calendar.gmt.dateComponents([.day], from: today, to: displayedDate).day ?? 0
    }

    private var navigationTitle: String {
        // 모든 케이스 동일 포맷: "M월 d일 (요일)" — 오늘/어제/내일도 절대 날짜로 표시.
        // 상대 마커는 하단 (오늘) floating 버튼이 대체. UTC anchor → formatter도 UTC로.
        let utc = TimeZone(identifier: "UTC") ?? .gmt
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
}

struct TodayList: View {

    let date: Date
    @Binding var sheet: ItemSheetMode?

    /// 루틴 정렬 snapshot — date 변경 시(view 재생성) 한 번 계산.
    /// 같은 date 내에서 체크 토글 시 즉시 reorder되지 않게 cache. 다음 navigation 시 재계산.
    @State private var stableRoutineOrder: [String] = []

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
    private var ntdsForDate: [OccurrenceRow] {
        let now = Date()
        var result: [OccurrenceRow] = []

        for item in ntdItems {
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
        for item in routineItems {
            for start in item.occurrenceStartsCovering(date: date) {
                result.append(OccurrenceRow(item: item, occurrenceDate: start))
            }
        }
        return result
    }

    /// 루틴 섹션 표시 list — snapshot 적용.
    /// stableRoutineOrder가 비어있으면 fresh sort (첫 render), 있으면 cached order로 재배치.
    /// 새 occurrence는 cache에 없는 ID라 끝에 append됨.
    private func displayRoutines() -> [OccurrenceRow] {
        let current = routinesForDate
        if stableRoutineOrder.isEmpty {
            return sortedRoutines()
        }
        let idMap = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var result: [OccurrenceRow] = []
        var seen: Set<String> = []
        for id in stableRoutineOrder {
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

    /// 루틴 섹션 정렬 — 같은 Item occurrence 인접 유지 + 그룹 단위 pending/done 정렬.
    /// 1) 같은 Item의 occurrence들은 항상 인접 (chronological 순서 — 그룹 마지막=가장 최근)
    /// 2) Item 그룹 순서: 어떤 occurrence라도 pending인 그룹 먼저, 전부 done인 그룹은 섹션 끝으로
    /// 단순 occurrence별 split하면 같은 Item이 pending/done bucket으로 쪼개져 인접 깨짐 → 그룹 단위 split.
    private func sortedRoutines() -> [OccurrenceRow] {
        let routinesRaw = routinesForDate
        var byItem: [NSManagedObjectID: [OccurrenceRow]] = [:]
        var itemOrder: [NSManagedObjectID] = []
        for row in routinesRaw {
            if byItem[row.item.objectID] == nil { itemOrder.append(row.item.objectID) }
            byItem[row.item.objectID, default: []].append(row)
        }
        var pendingGroups: [[OccurrenceRow]] = []
        var doneGroups: [[OccurrenceRow]] = []
        for itemID in itemOrder {
            guard let group = byItem[itemID] else { continue }
            let hasAnyPending = group.contains { !$0.item.isCompletedForDate($0.occurrenceDate) }
            if hasAnyPending { pendingGroups.append(group) } else { doneGroups.append(group) }
        }
        return (pendingGroups + doneGroups).flatMap { $0 }
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
        // 루틴 섹션: snapshot 적용 list (같은 date 내에서 체크 토글에 의한 reorder 회피).
        let routinesSorted = displayRoutines()
        List {
            Section("today.section.not_todo") {
                if ntdsForDate.isEmpty {
                    emptyRow("today.empty.not_todo")
                } else {
                    // 그룹 = List row 1개. 내부 VStack 간격으로 occurrence 간 간격 직접 제어 (List 강제 높이 회피).
                    ForEach(itemGroups(ntdsForDate)) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(group.occurrences.enumerated()), id: \.element.id) { idx, occ in
                                let isLast = (idx == group.occurrences.count - 1)
                                Button {
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
                    ForEach(itemGroups(routinesSorted)) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(group.occurrences.enumerated()), id: \.element.id) { idx, occ in
                                let isLast = (idx == group.occurrences.count - 1)
                                rowButton(
                                    for: group.item,
                                    occurrenceStart: occ.occurrenceDate,
                                    compact: !isLast
                                )
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // 하단 (+) FAB(56pt + padding 20pt)에 마지막 row가 가리지 않도록 스크롤 여백 확보.
        .contentMargins(.bottom, 96, for: .scrollContent)
        // 첫 render 후 루틴 정렬 snapshot 캡처 — 이후 체크 토글로 인한 reorder 회피.
        // date 변경 시 부모 .id(displayedDate)로 view 재생성 → @State 초기화 → 다시 캡처.
        .onAppear {
            if stableRoutineOrder.isEmpty {
                stableRoutineOrder = sortedRoutines().map { $0.id }
            }
        }
    }

    /// occurrenceStart override + compact mode 전달.
    /// compact=true면 ItemRow가 아이콘+제목+d-day만 노출 (그룹 마지막 외 row용).
    private func rowButton(for item: Item, occurrenceStart: Date? = nil, compact: Bool = false) -> some View {
        Button {
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
