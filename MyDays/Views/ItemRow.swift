import CoreData
import SwiftUI

struct ItemRow: View {

    /// 호출 view 별 표시 정체성.
    /// - today: 오늘탭/ArchiveView — 시각 라벨, 체크박스(루틴은 referenceDate 기준 토글)
    /// - list: 목록탭 — D-day + 반복 요약, 루틴 체크 불가(repeat 아이콘 표시)
    enum DisplayMode { case today, list }

    @ObservedObject var item: Item
    var referenceDate: Date = Date()
    var mode: DisplayMode = .today
    /// 명시 occurrence start override — 같은 Item이 같은 view에 여러 occurrence로 노출될 때 각 row가 다른 occurrence를 표시.
    /// nil이면 referenceDate로부터 자동 계산 (기존 동작).
    var occurrenceStartOverride: Date? = nil
    /// compact 표시 — 그룹 내 마지막이 아닌 row용. 아이콘 + 제목 + d-day만 노출 (notes/status icons 숨김).
    var compactMode: Bool = false
    @Environment(\.managedObjectContext) private var context
    @Environment(\.cancelMode) private var cancelMode
    @Environment(\.itemPickerMode) private var itemPickerMode
    @Environment(\.pickedItemID) private var pickedItemID
    @Environment(\.onPickItem) private var onPickItem
    @Environment(\.colorScheme) private var colorScheme
    @State private var showCompleteSheet = false
    @State private var showCancelSheet = false
    /// 체크 transient 상태 — 사용자가 체크 탭한 직후 0.5s 동안 true.
    /// 실제 Item.itemStatus/RC mutation은 deferred → 그동안 icon만 먼저 filled로 표시.
    /// 0.5s 후 mutation + save → FetchRequest가 row를 fade-out으로 제거.
    /// 안 그러면 mutation 즉시 → FetchRequest가 immediately remove → 체크 시각이 안 보임.
    @State private var pendingCompletion: Bool = false
    /// 체크리스트 inline expand 토글. row마다 독립 — 한 row 펼친다고 다른 row 자동 닫지 않음.
    /// 일자/탭 navigation 시 ItemRow 재생성으로 자동 reset.
    @State private var checklistExpanded: Bool = false

    /// 루틴 체크박스 동작 여부. 목록탭은 referenceDate 컨텍스트가 명확하지 않아 비활성.
    private var routineCheckable: Bool { mode != .list }

    var body: some View {
        // Adaptive TimelineView — 시각 라벨/색상 전환을 시간 흐름에 따라 자동 갱신.
        // target 임박 시 1초/30초, 평소 60초로 가변해 배터리 saving.
        let schedule = AdaptiveCountdownSchedule { now in
            item.nextCountdownInstant(viewDate: referenceDate, now: now)
        }
        TimelineView(schedule) { _ in
            VStack(alignment: .leading, spacing: 4) {
                rowContent
                    // 체크리스트 expand로 인한 title 자리이동 보간을 rowContent 한정으로 차단.
                    // outer VStack에 부착하면 FetchRequest의 row 제거(완료 체크 fade-out) 애니메이션까지
                    // 같이 막힘 — 체크리스트 있는 항목 완료 시 fade-out 안 됨.
                    .animation(nil, value: checklistExpanded)
                if checklistExpanded, hasChecklistDisplay {
                    checklistExpansion
                        .padding(.leading, 40)
                }
            }
        }
        .sheet(isPresented: $showCompleteSheet) {
            TodoCompleteSheet { comment in
                performComplete(comment: comment)
            }
        }
        .sheet(isPresented: $showCancelSheet) {
            CancelTodoSheet { comment in
                performCancel(comment: comment)
            }
        }
    }

    /// 항목 선택 모드 + 선택된 row 여부 — background highlight 결정.
    private var isPickerSelected: Bool {
        itemPickerMode && pickedItemID != nil && pickedItemID == item.id
    }

    @ViewBuilder
    private var rowContent: some View {
        // .firstTextBaseline — leadingControl 아이콘(title3 SF Symbol)이 title 텍스트(body)의 baseline에 정렬.
        // .top 정렬은 icon line box top과 text line box top이 같아 cap height 차이로 icon이 위로 떠 보이는데,
        // baseline 매칭이 시각적으로 가장 자연스러움.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // 항목 선택 모드 — 모든 row 앞에 checkmark slot 예약 (mode 안에서 toggle 시 layout shift 회피).
            // selected = checkmark.circle.fill (accent), unselected = circle outline (faint).
            if itemPickerMode {
                Image(systemName: isPickerSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isPickerSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                    .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }
            }
            leadingControl
                // SF Symbol baseline이 text baseline과 미세히 어긋나 icon이 살짝 위로 보임 — 2pt 내려서 시각 중심 보정.
                // d[.firstTextBaseline] - 2 → 내가 주장하는 baseline이 2pt 위 → HStack이 정렬 시 view를 2pt 아래로 밀어줌.
                .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let categoryBarColor {
                        Rectangle()
                            .fill(categoryBarColor)
                            .frame(width: 3, height: 14)
                            // firstTextBaseline 정렬 시 Rectangle은 bottom이 baseline에 매칭됨 → 텍스트 descender 영역만큼 위로 떠 보임.
                            // baseline anchor를 height의 80% 위치로 옮겨 (텍스트 baseline 위치와 매칭) 시각적으로 텍스트와 센터 정렬.
                            .alignmentGuide(.firstTextBaseline) { d in d.height * 0.9 }
                    }
                    Text(item.title ?? "")
                        .foregroundStyle(isCompletedForDate ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let todLabel = timeOfDayLabel {
                        Text(todLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                    }
                    if let dueLabel = dueDayLabel {
                        Text(dueLabel)
                            .font(.caption)
                            .foregroundStyle(item.isOverdue(referenceDate: referenceDate) ? .red : .secondary)
                            .layoutPriority(1)
                    }
                }

                if !compactMode, let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if !compactMode, hasAnyStatusIconOrMeta {
                    statusIcons
                }

                // 컴팩트(그룹 routine) 모드 — 체크리스트 chip은 title 바로 아래 별도 row.
                // notes/statusIcons는 compactMode에서 숨김 정책 유지 (chip만 노출).
                if compactMode, hasChecklistDisplay {
                    checklistChip
                }
                // 주의: checklistExpansion은 rowContent 밖(body 레벨)에 부착됨.
                // 여기에 두면 row 내부 VStack이 expansion 높이를 흡수해 title이 중앙으로 떠 보임.
            }

            // 취소 모드 + 미완료/미취소 row에만 (x) 노출.
            // ItemRow는 Todo 전용 — 모든 row가 cancel 대상.
            if cancelMode && !isCompletedForDate && !isCancelled {
                Button {
                    showCancelSheet = true
                } label: {
                    Image(systemName: "nosign")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                // leadingControl과 동일 — SF Symbol baseline 보정으로 살짝 내려 텍스트 시각 중심에 정렬.
                .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - leading control

    @ViewBuilder
    private var leadingControl: some View {
        // ItemRow는 Todo 전용. 반복 + 목록 탭 모드는 routineStatusIcon (체크 불가), 그 외 todoCheckbox.
        if isRoutine && !routineCheckable {
            routineStatusIcon
        } else {
            todoCheckbox
        }
    }

    /// Todo/routine 일반 체크박스 아이콘:
    /// - 완료: checkmark.circle.fill + accent
    /// - 취소(.failed / RC failed=true): slash.circle (outline) + secondary
    /// - 진행 중: circle + accent (파란 outline)
    /// - 그 외 pending: circle + secondary (회색 outline)
    private var todoCheckbox: some View {
        let style = todoCheckboxStyle()
        return Button(action: toggleDone) {
            Image(systemName: style.icon)
                .font(.title3)
                .foregroundStyle(style.color)
        }
        .buttonStyle(.plain)
        // picker 모드에선 tap 차단 — 시각은 유지(상태 표시), 액션은 leftmost 선택 체크에 위임.
        .allowsHitTesting(!itemPickerMode)
    }

    private func todoCheckboxStyle() -> (icon: String, color: Color) {
        if isCompletedForDate { return ("checkmark.circle.fill", .accentColor) }
        if isCancelled { return ("nosign", .secondary) }
        if isInProgress { return ("circle", .accentColor) }
        return ("circle", .secondary)
    }

    /// 진행 중 판정 — Item.isInProgress 위임. occurrenceStartOverride 있으면 해당 occurrence 기준.
    private var isInProgress: Bool {
        item.isInProgress(viewDate: referenceDate, now: Date(), occurrenceStartOverride: occurrenceStartOverride)
    }

    /// 반복 Todo 아이콘 (목록탭 등 routineCheckable=false). NTD 4-state와 같은 의미.
    /// - pending + 진행 중 아님: `arrow.triangle.2.circlepath.circle` + secondary (회색 라인)
    /// - pending + 진행 중: `arrow.triangle.2.circlepath.circle` + accent (파란 라인)
    /// - done: `arrow.triangle.2.circlepath.circle.fill` + accent (파란 filled)
    /// - failed: 같은 fill + secondary (실제 발생 드묾)
    @ViewBuilder
    private var routineStatusIcon: some View {
        let (name, color) = routineIconStyle()
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(color)
    }

    private func routineIconStyle() -> (String, Color) {
        switch item.itemStatus {
        case .done:   return ("arrow.triangle.2.circlepath.circle.fill", Color.accentColor)
        case .failed: return ("arrow.triangle.2.circlepath.circle.fill", Color.secondary)
        default: break
        }
        // pending — isInProgress(시작 instant 후 + 종료 instant 전)면 accent, 아니면 secondary.
        return ("arrow.triangle.2.circlepath.circle",
                isInProgress ? Color.accentColor : Color.secondary)
    }

    // MARK: - completion

    private var isRoutine: Bool { item.recurrenceRule != nil }

    private var isCompletedForDate: Bool {
        // transient 체크 — 실제 mutation 전 0.5s 동안 icon만 filled로 표시 (체크 시각 피드백).
        if pendingCompletion { return true }
        if isRoutine {
            // occurrence별 완료 — multi-day occurrence가 같은 날에 여러 개 있을 때 각각 독립 체크.
            // override 있으면 occurrence start 기준, 없으면 referenceDate (단일 occurrence 케이스).
            let day = occurrenceStartOverride ?? referenceDate
            return item.isCompletedForDate(day)
        }
        return item.itemStatus == .done
    }

    /// 취소(포기) 상태 — Todo cancel + NTD 포기 공용.
    /// 반복은 RoutineCompletion(failed=true), 1회성은 Item.status=.failed.
    private var isCancelled: Bool {
        if isRoutine {
            return item.routineRecord(on: canonicalCompletionDay)?.failed ?? false
        }
        return item.itemStatus == .failed
    }

    /// 체크 토글 — 단일/반복 통일 처리.
    /// 1) 모든 항목은 `RoutineCompletion` 레코드 생성/삭제 (per-occurrence 기록 = 활동 기록 소스)
    /// 2) 1회성은 추가로 `Item.status`를 cache로 유지 → ListView 완료 섹션 fetch에서 빠른 분류
    /// 반복은 Item.status를 .pending 그대로 (rule이 계속 진행 중이라 의미 X).
    /// RC.date 기준:
    ///   - 반복: referenceDate (그 occurrence date)
    ///   - 1회성: item.startDate (canonical event date) — 다양한 day view에서 같은 RC 매칭
    ///
    /// 신규 체크 + Todo + 미래 일정(시작 instant 전): 사유 입력 시트로 분기 (NTD 포기와 동일 패턴).
    /// 시간 미설정 일정은 startHour=0(자정)이라 보통 미래로 잡히지 않음 — 의도된 동작.
    private func toggleDone() {
        let now = Date()
        let day = canonicalCompletionDay
        let completions = (item.completions as? Set<RoutineCompletion>) ?? []
        let existing = completions.first { c in
            guard let d = c.date else { return false }
            return Calendar.gmt.isDate(d, inSameDayAs: day)
        }

        if let existing {
            context.delete(existing)
            if !isRoutine {
                item.itemStatus = .pending
                item.completedAt = nil
            }
            item.updatedAt = now
            // performComplete가 남긴 transient 상태 해제 — 안 그러면 isCompletedForDate가
            // pendingCompletion=true를 우선해 uncheck가 시각적으로 안 보임.
            pendingCompletion = false
            ItemEvent.log(.uncompleted, on: item, in: context)
            saveContext()
            // 미리 체크해서 cancel됐던 알림 재등록 — 사용자가 마음 바꿔 uncheck하면 해당 occurrence
            // (또는 다음 future occurrence들)에 대해 시작/종료 알림 다시 fire되어야 함.
            // syncNotifications가 prefix 일괄 cancel + future occurrence 일괄 register라 안전.
            item.syncNotifications()
            return
        }

        // 신규 체크. 미래 일정이면 사유 시트로 분기 (ItemRow는 Todo 전용).
        if isFutureSchedule(now: now) {
            showCompleteSheet = true
            return
        }
        performComplete(comment: nil)
    }

    /// 취소 시트 확정 시 호출 — Item.cancel로 위임 (RC failed + .failed status + ItemEvent.log).
    private func performCancel(comment: String?) {
        let day = canonicalCompletionDay
        // 완료 체크와 동일한 animation 정책 — row 제거·재배치를 부드럽게.
        withAnimation(.easeInOut(duration: 0.35)) {
            item.cancel(occurrenceDate: day, comment: comment, in: context)
        }
    }

    /// 시트 확정 또는 즉시 완료의 공통 경로.
    /// comment: nil = 사유 없음 / non-nil = 사유 텍스트(RC.comment + ItemEvent.note에 동일 저장).
    ///
    /// **타이밍**: pendingCompletion=true → 0.5s 시각 피드백 → mutation+save → row fade-out.
    /// FetchRequest는 context object change 시점에 predicate 재평가하므로 mutation을 직접 호출하면
    /// row가 즉시 사라져 체크 아이콘 flip이 안 보임. 그래서 mutation을 deferred로 미룸.
    private func performComplete(comment: String?) {
        // 1. 즉시 시각 피드백 — pendingCompletion=true → isCompletedForDate=true → icon=checkmark.circle.fill.
        withAnimation(.easeInOut(duration: 0.15)) {
            pendingCompletion = true
        }
        // 2. 0.5s 후 실제 mutation + save. withAnimation으로 row 제거 fade-out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let now = Date()
            let day = canonicalCompletionDay
            let comp = RoutineCompletion(context: context)
            comp.id = UUID()
            comp.date = day
            comp.done = true
            comp.completedAt = now
            comp.comment = comment
            comp.item = item
            if !isRoutine {
                item.itemStatus = .done
                item.completedAt = now
                // 1회성: 모든 미래 알림 취소.
                item.cancelAllNotifications()
            } else {
                // 반복: 그 occurrence의 알림만 취소 (다음 occurrence 알림 유지).
                // 미리 체크 시 시작/종료 알림이 그대로 fire되는 버그 방지.
                item.cancelNotifications(forOccurrence: day)
            }
            item.updatedAt = now
            ItemEvent.log(.completed, on: item, in: context, note: comment)
            do {
                try withAnimation(.easeInOut(duration: 0.5)) {
                    try context.save()
                }
            } catch {
                assertionFailure("Toggle save failed: \(error)")
            }
            // mutation 완료 — pendingCompletion 해제. 이후 isCompletedForDate는 item.itemStatus로 판정.
            pendingCompletion = false
        }
    }

    /// RC.date 기준일 —
    /// 반복: occurrence start 기준 (override > 자동 계산 > referenceDate). multi-day occurrence가 같은 날에
    ///       여러 개 노출될 때 각 occurrence를 독립 RC로 토글하기 위함.
    /// 1회성: startDate (canonical event date) — 다양한 day view에서 같은 RC 매칭.
    private var canonicalCompletionDay: Date {
        if isRoutine {
            let day = occurrenceStartOverride ?? referenceDate
            return Calendar.gmt.startOfDay(for: day)
        }
        return Calendar.gmt.startOfDay(for: item.startDate ?? referenceDate)
    }

    /// 미래 일정 판정 — 적용 occurrence의 시작 instant가 now보다 미래면 true.
    /// - 반복: `referenceOccurrenceStartDate(viewDate:)`로 적용 occurrence 결정 (오늘탭 swipe로 어제 routine 체크 시 미래 아님)
    /// - 1회성: `effectiveStartInstant`
    /// startDate 없음(Someday) → false.
    private func isFutureSchedule(now: Date) -> Bool {
        if isRoutine {
            // override 있으면 그 occurrence 기준 — multi-occurrence 그룹 내 각 row가 자신의 시작 instant로 판정.
            let occStartOpt = occurrenceStartOverride ?? item.referenceOccurrenceStartDate(viewDate: referenceDate)
            guard let occStart = occStartOpt,
                  let inst = Item.localInstant(fromCalendarDate: occStart, hour: item.startHourInt)
            else { return false }
            return now < inst
        }
        guard let inst = item.effectiveStartInstant else { return false }
        return now < inst
    }

    private func saveContext() {
        // 체크/해제로 인한 row 제거·재배치를 부드럽게 — easeInOut 350ms로 fade·slide 결합.
        // FetchRequest(animation: .default)만 의존하면 너무 빨라 인지 안 됨.
        do {
            try withAnimation(.easeInOut(duration: 0.35)) {
                try context.save()
            }
        } catch {
            assertionFailure("Toggle save failed: \(error)")
        }
    }

    /// 제목 앞 세로 bar 색상.
    /// Todo 카테고리 color bar — 매칭 안 되면 nil (bar 안 보임).
    private var categoryBarColor: Color? {
        guard let cat = item.category,
              let raw = cat.colorHex,
              let cc = CategoryColor(rawValue: raw)
        else { return nil }
        return cc.color
    }

    // MARK: - status icons

    private var hasReminders: Bool { item.hasReminders }

    private var hasAnyStatusIconOrMeta: Bool {
        if hasChecklistDisplay { return true }
        if item.itemPriority != .none { return true }
        if streakValue != nil { return true }
        if hasReminders { return true }
        if recurrenceText != nil { return true }
        return false
    }

    /// 순서: 깃발 / 체크리스트 칩 / streak / 알림 / 반복.
    /// today·list 모드 공통 — Todo 메타 정보 일관 노출 (NTD duration은 MissionRow가 처리).
    @ViewBuilder
    private var statusIcons: some View {
        HStack(spacing: 8) {
            if item.itemPriority != .none {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(flagColor(for: item.itemPriority))
            }
            if hasChecklistDisplay {
                checklistChip
            }
            if let streak = streakValue {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                    Text(verbatim: "\(streak)")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if hasReminders {
                Image(systemName: "bell")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 반복 패턴 — repeat 아이콘 + 요약 텍스트.
            if let r = recurrenceText {
                HStack(spacing: 2) {
                    Image(systemName: "repeat")
                    Text(verbatim: r)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var streakValue: Int? { item.streakValueIfRoutine(referenceDate: referenceDate) }

    // MARK: - 체크리스트 (chip + inline expand)

    /// 이 row의 체크리스트 occurrenceDate. 반복은 occurrence별, 1회성/Someday는 sentinel.
    private var checklistOccurrenceDate: Date {
        item.checklistOccurrenceDate(occurrenceStartOverride: occurrenceStartOverride, referenceDate: referenceDate)
    }

    private var displayedChecklist: [ChecklistItem] {
        item.displayedChecklist(forOccurrence: checklistOccurrenceDate)
    }

    private var checklistProgress: (checked: Int, total: Int) {
        item.checklistProgress(forOccurrence: checklistOccurrenceDate)
    }

    /// chip 표시 여부. 합집합 후 표시할 항목이 1개라도 있으면 true.
    private var hasChecklistDisplay: Bool {
        item.hasDisplayableChecklist(forOccurrence: checklistOccurrenceDate)
    }

    /// 체크리스트 chip — `☑ N/M ›` 컴팩트 캡슐. 탭 시 expand 토글.
    /// chevron은 회전 애니메이션으로 펼침/접힘 상태 표시 (시각적 일관성 — 캡슐 안에서 자연스럽게).
    @ViewBuilder
    private var checklistChip: some View {
        let progress = checklistProgress
        Button {
            checklistExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.square.fill")
                    .font(.caption)
                Text(verbatim: "\(progress.checked)/\(progress.total)")
                    .font(.caption)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .rotationEffect(.degrees(checklistExpanded ? 90 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // secondarySystemFill — light/dark 양쪽에서 List 배경과 명확히 구분되는 semantic fill.
            // systemGray6은 다크모드에서 grouped List 배경과 비슷한 톤이라 chip이 묻혀 보임.
            .background(Capsule().fill(Color(.secondarySystemFill)))
        }
        .buttonStyle(.plain)
        // chip이 외부 ambient animation(List row resize 등) 영향을 받지 않도록 면제.
        // title은 외곽 layout으로 고정되지만 chip은 layout 변화에 끌려가서 위/아래로 움직이는 현상 차단.
        .transaction { txn in
            txn.animation = nil
            txn.disablesAnimations = true
        }
    }

    /// expand 시 chip 아래 체크박스 목록.
    /// soft-deleted 항목도 historical check가 있으면 표시 (합집합).
    /// 호출 측에서 frame(height) + clipped로 layout-driven 애니메이션 처리.
    @ViewBuilder
    private var checklistExpansion: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(displayedChecklist, id: \.objectID) { ci in
                checklistRow(ci)
            }
        }
        .padding(.leading, 2)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func checklistRow(_ ci: ChecklistItem) -> some View {
        let checked = ci.isChecked(forOccurrence: checklistOccurrenceDate)
        Button {
            toggleChecklistCheck(ci)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                Text(verbatim: ci.title ?? "")
                    .font(.callout)
                    .foregroundStyle(checked ? .secondary : .primary)
                    .strikethrough(checked, color: .secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleChecklistCheck(_ ci: ChecklistItem) {
        // 체크 상태 변화는 row만 갱신 → 부드러운 transition.
        withAnimation(.easeInOut(duration: 0.2)) {
            Item.toggleChecklistCheck(
                for: ci,
                occurrenceDate: checklistOccurrenceDate,
                in: context
            )
        }
        do {
            try context.save()
        } catch {
            assertionFailure("Checklist toggle save failed: \(error)")
        }
    }

    private func flagColor(for priority: Priority) -> Color {
        switch priority {
        case .high:   return .red
        case .medium: return .yellow
        case .low:    return .blue
        case .none:   return .secondary
        }
    }

    /// ListView right-side label.
    /// Todo:
    ///   - 완료: "오후 5시 완료" (completedAt 시각)
    ///   - 당일 시작 예정 (start today, now<start): "오늘 오전 11시 시작"
    ///   - 당일 종료 시각 있음 (due today + dueHour): "오늘 오후 5시 종료"
    ///   - 그 외 진행 중 / 미래: D-X (routine 다음 occurrence / 1회성 마감)
    /// NTD:
    ///   - 완료(1회성): "오후 5시 완료" (completedAt)
    ///   - 포기(1회성): "포기"
    ///   - 시작 전: "5시간 30분 후 시작"
    ///   - 진행 중 (목표 있음): "1시간 15분 남음"
    ///   - 진행 중 (목표 없음): "2시간 30분 진행 중"
    /// 시간 포맷: 8h+ "%시간", 1~7h "%시간 %분", <1h "%분", <1m "%초" (Item.formatNTDDuration)
    private var dueDayLabel: String? {
        let now = Date()
        return todoUnifiedLabel(now: now)
    }

    private var recurrenceText: String? { item.recurrenceTextSummary }

    // MARK: Todo label (통일 원칙 적용)
    //
    // 원칙 0: d-day는 real today(`.todayCalendarAnchor`) 기준 — view 일자 무관.
    // 원칙 1: 일정 정보(시작/종료일시) 기반. 사용자 완료 시점(completedAt) 무시.
    // 원칙 2: 시작 instant 전 → 시작일 기준 D-N. 시작 후 → 종료일 기준 D-N + "종료" prefix.
    //         예외: 시작일==종료일(단일)이면 prefix 생략.
    // 원칙 3: 시각 설정 + (시작/종료가 오늘) → 시각 라벨 ("X시 시작" / "X시 종료"). 그 외 d-day.
    // 적용: 1회성/반복 통일. 반복은 적용 occurrence start를 anchor로 1회성처럼 처리.

    /// Todo 라벨 entry — 적용 occurrence start/due 계산 후 scheduleLabel로 위임.
    /// occurrenceStartOverride가 있으면 그것 우선, 없으면 referenceDate로 자동 계산.
    private func todoUnifiedLabel(now: Date) -> String? {
        // list mode + 1회성 + 완료/취소: completedAt 시각 표시 (NTD와 동일 패턴).
        // 보관함·목록의 완료 섹션에서 "%@ 완료" / "%@ 취소" 형태로 라벨링.
        // today mode에서는 일정 정보 기반 라벨 유지(원칙 1).
        // 반복은 occurrence가 계속되므로 적용 안 함 (status는 pending 유지).
        if mode == .list, !isRoutine,
           (item.itemStatus == .done || item.itemStatus == .failed),
           let inst = item.completedAt {
            let key = (item.itemStatus == .failed) ? "todo.label.cancelled_at_format" : "todo.label.done_at_format"
            return String.localizedStringWithFormat(
                NSLocalizedString(key, comment: ""),
                MissionRow.completionTimeText(instant: inst)
            )
        }
        guard let occStart = occurrenceStartOverride ?? item.referenceOccurrenceStartDate(viewDate: referenceDate) else {
            return nil
        }
        let span = isRoutine ? item.spanDays : 0
        // 1회성: occurrence start=startDate, due=effectiveDueDate.
        // 반복: occurrence start=occStart, due=occStart+spanDays.
        let occDue: Date = {
            if isRoutine {
                return Calendar.gmt.date(byAdding: .day, value: span, to: occStart) ?? occStart
            }
            return item.effectiveDueDate ?? occStart
        }()
        // today mode 여부 + view가 real today 여부 — d-day 출력 방식 결정.
        let realTodayDay = Calendar.gmt.startOfDay(for: .todayCalendarAnchor)
        let viewDay = Calendar.gmt.startOfDay(for: referenceDate)
        let isTodayMode = (mode == .today)
        let isViewToday = Calendar.gmt.isDate(viewDay, inSameDayAs: realTodayDay)
        return scheduleLabel(
            startDay: Calendar.gmt.startOfDay(for: occStart),
            dueDay: Calendar.gmt.startOfDay(for: occDue),
            startInst: Item.localInstant(fromCalendarDate: occStart, hour: item.startHourInt),
            startH: item.startHourInt,
            dueH: item.dueHourInt,
            hasExplicitTime: item.hasExplicitTime,
            isTodayMode: isTodayMode,
            isViewToday: isViewToday,
            now: now
        )
    }

    /// 원칙 2/3 매핑 — 통일 라벨 계산.
    private func scheduleLabel(
        startDay: Date, dueDay: Date,
        startInst: Date?,
        startH: Int, dueH: Int,
        hasExplicitTime: Bool,
        isTodayMode: Bool,
        isViewToday: Bool,
        now: Date
    ) -> String? {
        let realTodayDay = Calendar.gmt.startOfDay(for: .todayCalendarAnchor)
        let isStartToday = Calendar.gmt.isDate(startDay, inSameDayAs: realTodayDay)
        let isDueToday = Calendar.gmt.isDate(dueDay, inSameDayAs: realTodayDay)
        let isSameDay = Calendar.gmt.isDate(startDay, inSameDayAs: dueDay)

        // 원칙 3: 시각 라벨 (시각 설정 + 오늘이 시작/종료일).
        // **view가 real today일 때만 적용** — 다른 날짜 페이지에서는 today-mode d-day 규칙으로 떨어져야
        // "view=5/27인데 5/26 시작 일정이 '9시 시작'으로 보이는" 혼동 회피.
        // list mode는 referenceDate가 항상 today라 isViewToday=true → 영향 없음.
        //
        // hasExplicitTime = startH > 0 || dueH < 24. 분기 결정 시 명시된 쪽 우선:
        // - hasEnd(dueH<24): "X시 종료" 가능
        // - hasStart(startH>0): "X시 시작" 가능
        // - start만 (dueH=24): 시작 전 → "X시 시작", 진행 중 → "오늘 종료" (start-only 종일)
        let hasEnd = dueH < 24
        let hasStart = startH > 0
        if hasExplicitTime && (!isTodayMode || isViewToday) {
            if isStartToday && isDueToday {
                // 시작=종료=오늘. 단일시간(s==e, 둘 다 명시)이거나 시작 전 → "s시 시작". 시작 후 → "e시 종료".
                if hasEnd && hasStart && startH == dueH {
                    if isTodayMode && isViewToday {
                        return hourLabel(forHour: startH)
                    }
                    return startTimeLabel(startH)
                }
                // 시작 전 — start가 명시됐고 아직 안 옴.
                if hasStart, let inst = startInst, now < inst {
                    return startTimeLabel(startH)
                }
                // 시작 후. 종료 시각 있으면 "X시 종료".
                if hasEnd {
                    return endTimeLabel(dueH)
                }
                // start만 + 진행 중 → "오늘 종료" (start-only 종일 패턴).
                return String(localized: "todo.list.ends_today")
            }
            if isDueToday && hasEnd {
                return endTimeLabel(dueH)
            }
            if isStartToday && hasStart {
                return startTimeLabel(startH)
            }
            // 그 외 — d-day fall through
        }

        // 오늘탭 (today mode) d-day 규칙 — view date 자체가 일자 정보 제공:
        //   - 단일 (startDay == dueDay): nil — 라벨 없음
        //   - 기간 (startDay != dueDay):
        //     · view=today + 종료일=today → "오늘 종료"
        //     · 그 외 → "M월 d일 종료" (절대 종료일자, D-N 아님)
        if isTodayMode {
            // 오늘 페이지인데 dueDay가 과거 — overdue. 단일/기간 무관 D+N 빨강 라벨로 통일.
            // (`isSameDay` 분기보다 먼저 — 단일 어제 일정도 라벨 노출되도록.)
            // 색상은 ItemRow의 dueDayLabel 색이 isOverdue 검사로 자동 red 적용.
            if isViewToday && dueDay < realTodayDay {
                let days = Calendar.gmt.dateComponents([.day], from: realTodayDay, to: dueDay).day ?? 0
                return formatDDay(days)
            }
            if isSameDay { return nil }
            if isViewToday && isDueToday {
                return String(localized: "todo.list.ends_today")
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("todo.today.ends_on_format", comment: ""),
                Self.absoluteDayLabel(dueDay)
            )
        }

        // mode == .list: 기존 d-day 중심 로직 (D-N 형식)
        if let inst = startInst, now < inst {
            let days = Calendar.gmt.dateComponents([.day], from: realTodayDay, to: startDay).day ?? 0
            return formatDDay(days)
        }
        // 종료 시각 없음(hasEnd=false) + 오늘이 종료일 → "오늘"/"오늘 종료" 라벨.
        // hasExplicitTime이 start-only로 true여도 (dueH=24) 이 분기로 옴 — 시각 라벨 분기는 위에서
        // 처리됐고, 여기 떨어진 건 isStartToday/isDueToday 케이스 아닌 fall-through 케이스.
        if !hasEnd && isDueToday {
            if isSameDay {
                return String(localized: "todo.list.today")
            }
            return String(localized: "todo.list.ends_today")
        }
        let days = Calendar.gmt.dateComponents([.day], from: realTodayDay, to: dueDay).day ?? 0
        if isSameDay {
            return formatDDay(days)
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("todo.list.in_progress_dday_format", comment: ""),
            formatDDay(days)
        )
    }

    /// UTC anchor calendar date를 로케일 "M월 d일" / "MMM d" 형식으로.
    /// timezone=UTC 강제 — anchor date가 timezone shift로 어긋나지 않게.
    private static func absoluteDayLabel(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: day)
    }

    private func startTimeLabel(_ h: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("todo.list.today_start_format", comment: ""),
            hourLabel(forHour: h)
        )
    }

    private func endTimeLabel(_ h: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("todo.list.today_end_format", comment: ""),
            hourLabel(forHour: h)
        )
    }

    // MARK: format helpers
    // formatDDay는 `Views/RowHelpers.swift`의 free 함수로 이전 (ItemRow/MissionRow 공유).

    /// "오후 5시" / "5:00 PM" — 시스템 12h/24h, hour-level만.
    private func hourLabel(forHour h: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("j")
        var comps = DateComponents()
        comps.hour = h
        comps.minute = 0
        guard let date = Calendar.current.date(from: comps) else { return "\(h)" }
        return formatter.string(from: date)
    }

    /// instant → "오후 5시" 형식 (분 무시, 시간만).
    private func hourLabel(from instant: Date) -> String {
        let hour = Calendar.current.component(.hour, from: instant)
        return hourLabel(forHour: hour)
    }

    // legacy: 기존 timeOfDayLabel 사용처는 dueDayLabel에 통합되어 미사용.
    // 캡션2(시간대 chip) 표시도 제거됨.
    private var timeOfDayLabel: String? { nil }

}
