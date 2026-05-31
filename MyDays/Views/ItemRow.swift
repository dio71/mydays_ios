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
    @State private var presentFocusSession: Bool = false

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
        .fullScreenCover(isPresented: $presentFocusSession) {
            FocusSessionView(item: item, occurrenceDate: focusOccurrenceDate)
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

            // 습관 trailing 체크 버튼 — leading icon은 display only이라 사용자에게 명시적 체크 액션 제공.
            // 정책 (습관은 "오늘/이전에 했나/안 했나" 관점):
            //   - **오늘 + 과거 일자만 노출** — 미래 일자는 미리 완료 의미 없음 → hide
            //   - 완료/미완료 무관하게 노출 — 미스 클릭 해제용 (checked square 보이면 체크 해제 가능)
            //   - 과거 일자도 노출 — 까먹고 안 한 거 나중에 기록 가능
            //   - 취소 모드일 땐 (x) 버튼 우선
            // 습관 trailing 체크 — 오늘/보관함 모드만. 목록 탭에선 숨김 (NTD progress·활동 progress와 동일 정책 — D-day 중심 조망).
            if isHabit && mode != .list && !isFutureDate && !isItemNotYetStarted && !cancelMode {
                habitTrailingCheck
            }

            // 활동 trailing — progress text + quick [+N] 버튼.
            // 정책: 오늘/보관함 모드만 노출. 목록 탭(.list)에선 숨김 — NTD가 목록 탭에서 progress 안 보이는 것과 동일.
            //       (목록 탭은 D-day 중심 조망용 — progress 인터랙션은 오늘 탭에서만 수행)
            // 미래 일자 / 시작 전 / 취소 모드 제외.
            if isActivity && mode != .list && !isFutureDate && !isItemNotYetStarted && !cancelMode {
                activityTrailingProgress
            }

            // 집중 trailing — progress capsule + ▶ 시작 버튼.
            // 정책: 오늘 모드 + 오늘 일자만 (다른 일자 시작은 의미 없음 — 사용자가 원하는 시점에 시작).
            // 진행 중인 active session이 있으면 ▶ disabled (전역 single-active).
            if isFocus && mode != .list && !isFutureDate && !isItemNotYetStarted && !cancelMode {
                focusTrailingProgress
            }

            // 취소 모드 + 미완료/미취소 row에만 (x) 노출.
            // NTD는 NTDRow가 자체 처리. 습관은 cancel 의미 없음 (단순 미체크가 곧 미수행) → 제외.
            // 여기 (x)는 Todo(1회성/루틴) 한정 — 미래 일자도 허용 (미리 취소 가능).
            if cancelMode && !isGoal && !isCompletedForDate && !isCancelled {
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
        // 목표(절제/활동/집중/습관) — 사용자 지정 goalIcon + goalColor 사용. 4-state 시각 유지.
        // 모든 목표 type은 leading icon은 display only. 습관은 trailing square check 버튼으로 toggleDone.
        // iconName 없는 legacy NTD는 기존 clock fallback.
        if isGoal, item.iconName != nil {
            goalLeadingIcon
        } else if isNTD {
            ntdStatusIcon
        } else if isRoutine && !routineCheckable {
            routineStatusIcon
        } else {
            todoCheckbox
        }
    }

    /// 습관 trailing 체크 버튼 — square / checkmark.square.fill 토글.
    /// 4-state(scheduled/inProgress/done/failed)는 goalLeadingIcon이 표현하고,
    /// 여기 trailing 버튼은 명시적 "체크" 액션만 담당.
    @ViewBuilder
    private var habitTrailingCheck: some View {
        let checked = isCompletedForDate
        Button(action: toggleDone) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.title3)
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        // leadingControl과 동일 baseline 보정.
        .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }
    }

    /// 습관 판정 — trailing 체크 버튼 노출 여부.
    private var isHabit: Bool { item.itemKind == .habit }

    /// 활동 판정 — trailing progress + [+N] 버튼 노출 여부.
    private var isActivity: Bool { item.itemKind == .activity }
    /// 집중 판정 — trailing progress + ▶ 버튼 노출 여부.
    private var isFocus: Bool { item.itemKind == .focus }

    /// activity occurrence date — 반복은 referenceDate, 1회성은 item.startDate 사용.
    private var activityOccurrenceDate: Date {
        if item.recurrenceRule != nil {
            return occurrenceStartOverride ?? referenceDate
        }
        return item.startDate ?? referenceDate
    }

    /// 활동 progress capsule (NTDRow 패턴 재활용) + 우측 (+) 심볼 버튼 or HK auto badge.
    /// progress fill 색·텍스트 색·(+) 색 모두 **goalColor 통일** (앱 tint 대신 항목 아이콘 색).
    /// - manual: 탭 → valueRecorded += step (target 도달 시 자동 done).
    /// - steps/distance (HK auto): (+) 버튼 대신 heart.fill badge (non-interactive).
    ///   HK sync는 RootView .task + scenePhase.active 트리거.
    @ViewBuilder
    private var activityTrailingProgress: some View {
        let target = item.activityTargetValueInt ?? 0
        let current = item.activityCurrentValue(on: activityOccurrenceDate)
        let step = Item.activityQuickStep(target: max(target, 1))
        let progress: Double = target > 0 ? min(Double(current) / Double(target), 1.0) : 0
        let goalColor = goalAccentColor
        let isAutoSource = item.activitySource != .manual
        // 과거 일자(occurrence가 어제 이전)는 입력 불가 — 당일에만 추가 가능.
        // progress bar는 계속 노출(그날 결과 확인) + trailing icon은 outline/secondary로 inactive 표시.
        let isPastDate = activityOccurrenceDate < .todayCalendarAnchor
        // spacing 2 + (+)/heart 크기를 NTD (x) (title3, ~20pt)에 맞춰 — 전체 trailing 폭이 NTD와 일치하도록.
        // 이전엔 (+) title2 + heart frame 28로 더 넓어서 progress capsule이 왼쪽으로 더 튀어나옴.
        HStack(spacing: 2) {
            // Progress capsule — goalColor 기반.
            ZStack(alignment: .trailing) {
                Capsule()
                    .fill(Color(.systemGray5))
                GeometryReader { geo in
                    let fullWidth = geo.size.width
                    let targetWidth = fullWidth * CGFloat(progress)
                    let fillWidth: CGFloat = progress > 0 ? max(4, targetWidth) : 0
                    Capsule()
                        .fill(goalColor.opacity(0.35))
                        .frame(width: fillWidth)
                }
                .clipShape(Capsule())
                Text(verbatim: "\(current)/\(target)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(colorScheme == .dark ? Color.primary : goalColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.trailing, 8)
            }
            .frame(width: 130, height: 22)

            // 과거 일자는 trailing 아이콘 완전 숨김 — progress bar만으로 그날 결과 표시.
            // 입력 정책: 활동은 당일에만 가능. 과거는 결과 확인만.
            if !isPastDate {
                if isAutoSource {
                    // HK auto source — heart.fill badge (non-interactive). Apple Health 시각 cue.
                    Image(systemName: "heart.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(goalColor.opacity(0.85))
                        .frame(width: 22, alignment: .center)
                        .accessibilityLabel(Text("activity.source.auto.accessibility"))
                } else {
                    // Manual — (+) 심볼 버튼. plus.circle.fill + goalColor.
                    // .title3 — NTD (x) 버튼과 같은 visual size로 alignment 일관성.
                    Button {
                        Item.incrementActivityValue(
                            for: item,
                            by: step,
                            occurrenceDate: activityOccurrenceDate,
                            in: context
                        )
                        saveContext()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(goalColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .layoutPriority(1)
        .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }
    }

    // MARK: - 집중 trailing

    /// 집중 occurrence date — 반복은 referenceDate, 1회성은 item.startDate. (활동과 동일 패턴)
    private var focusOccurrenceDate: Date {
        if item.recurrenceRule != nil {
            return occurrenceStartOverride ?? referenceDate
        }
        return item.startDate ?? referenceDate
    }

    /// 집중 trailing — progress capsule (활동과 동일 시각) + ▶ 시작 버튼.
    /// 진행 중 글로벌 active session이 이 item이면 ▶ 대신 stopwatch.fill 표시 (이미 modal에 있을 거지만).
    /// past 일자는 progress만 (▶ 숨김).
    @ViewBuilder
    private var focusTrailingProgress: some View {
        let target = item.activityTargetValueInt ?? 0
        let current = Int(item.focusCurrentMinutes(on: focusOccurrenceDate))
        let progress: Double = target > 0 ? min(Double(current) / Double(target), 1.0) : 0
        let goalColor = goalAccentColor
        let isPastDate = focusOccurrenceDate < .todayCalendarAnchor
        HStack(spacing: 2) {
            // Progress capsule — activity와 동일 시각. 분 단위로 표시 ("45/60").
            ZStack(alignment: .trailing) {
                Capsule()
                    .fill(Color(.systemGray5))
                GeometryReader { geo in
                    let fullWidth = geo.size.width
                    let targetWidth = fullWidth * CGFloat(progress)
                    let fillWidth: CGFloat = progress > 0 ? max(4, targetWidth) : 0
                    Capsule()
                        .fill(goalColor.opacity(0.35))
                        .frame(width: fillWidth)
                }
                .clipShape(Capsule())
                Text(verbatim: "\(current)/\(target)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(colorScheme == .dark ? Color.primary : goalColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.trailing, 8)
            }
            .frame(width: 130, height: 22)

            // ▶ 시작 버튼 — 오늘 일자에만. focusSessionPresentation 트리거.
            if !isPastDate {
                Button {
                    presentFocusSession = true
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(goalColor)
                }
                .buttonStyle(.plain)
            }
        }
        .layoutPriority(1)
        .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }
    }

    /// 목표 아이콘 색 (iconColorHex → Color). 미설정 시 accent fallback.
    /// 활동 progress · NTD progress 통일에 사용.
    private var goalAccentColor: Color {
        guard let raw = item.iconColorHex,
              let cc = CategoryColor(rawValue: raw) else {
            return Color.accentColor
        }
        return cc.color
    }

    /// 현재 view가 오늘 일자인지 — 미사용이지만 다른 케이스용 reserved.
    private var isViewingToday: Bool { referenceDate == .todayCalendarAnchor }

    /// 미래 일자 판정 — 습관 체크 버튼 노출 막기용 (미리 완료 의미 없음).
    private var isFutureDate: Bool { referenceDate > .todayCalendarAnchor }

    /// Item이 아직 시작 전인지 — startDate가 오늘보다 미래.
    /// 목록 탭에서 referenceDate는 오늘이지만 항목 startDate가 미래인 케이스 처리:
    /// 시작 안 한 습관/활동에 대한 trailing 체크/(+) 버튼을 막아 미리 완료 입력 방지.
    private var isItemNotYetStarted: Bool {
        guard let start = item.startDate else { return false }
        return start > .todayCalendarAnchor
    }

    private var isGoal: Bool { item.itemKind.isGoal }

    /// 목표 leading 아이콘 — Item.iconName + iconColorHex 기반. 4-state 색 패턴:
    ///   - scheduled (pending + 시작 전): 회색 outline circle + 회색 icon
    ///   - inProgress (pending + 진행 중): 투명 + goalColor icon
    ///   - done: goalColor full 배경 + 흰색 icon
    ///   - failed: 회색 full 배경 + 흰색 icon
    /// 크기: 20×20 (Todo 체크박스 title3 circle과 시각 균형). icon 11pt.
    @ViewBuilder
    private var goalLeadingIcon: some View {
        let icon = item.iconName.flatMap(GoalIcon.init(rawValue:))
        let color = item.iconColorHex.flatMap { CategoryColor(rawValue: $0) }?.color ?? .secondary
        let style = goalIconRenderStyle(color: color)
        ZStack {
            Circle()
                .fill(style.background)
                .overlay(Circle().strokeBorder(style.border, lineWidth: style.borderWidth))
                .frame(width: 20, height: 20)
            if let icon {
                Image(systemName: icon.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(style.iconColor)
            }
        }
        // SF Symbol Image와 시각 baseline 매칭 — ZStack은 default firstTextBaseline이 frame 하단(20pt)이라
        // text baseline 정렬 시 시각적으로 아래로 떠 보임. @ViewBuilder + 외곽 alignmentGuide 체인 때문에
        // 내부 alignmentGuide 효과가 약함 → offset으로 visual 보정 (layout box는 유지).
        .offset(y: -3)
    }

    private struct GoalIconRenderStyle {
        let background: Color
        let iconColor: Color
        let border: Color
        let borderWidth: CGFloat
    }

    /// 목표 아이콘의 4-state 시각 스타일.
    /// isCompletedForDate / isCancelled / isInProgress 기존 abstraction 재활용 — 1회성·반복 양쪽 호환.
    private func goalIconRenderStyle(color: Color) -> GoalIconRenderStyle {
        if isCompletedForDate {
            return GoalIconRenderStyle(background: color, iconColor: .white, border: .clear, borderWidth: 0)
        }
        if isCancelled {
            return GoalIconRenderStyle(background: Color(.systemGray3), iconColor: .white, border: .clear, borderWidth: 0)
        }
        if isInProgress {
            // 진행 중 — goalColor outline circle + goalColor icon. scheduled와 같은 outline 패턴, 색만 다름.
            return GoalIconRenderStyle(background: .clear, iconColor: color, border: color, borderWidth: 1)
        }
        // scheduled — 회색 outline circle + 회색 icon.
        return GoalIconRenderStyle(background: .clear, iconColor: .secondary, border: .secondary, borderWidth: 1)
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

    /// NTD 항목의 상태 표시 아이콘 (ListView 등에서 사용).
    /// 4-state 색·fill 조합:
    /// - pending + 시작 전 (scheduled): clock outline + secondary (회색) → 진행 전
    /// - pending + 진행 중 (inProgress): clock outline + accent (파랑) → 활성
    /// - done (자동/명시 완료):           clock.fill + accent (파랑) → 완료
    /// - failed (사용자 포기):            clock.fill + secondary (회색 filled) → 종료/중단
    @ViewBuilder
    private var ntdStatusIcon: some View {
        let (name, color) = Self.ntdIconStyle(for: item, now: Date())
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(color)
    }

    /// NTD 아이콘 스타일 계산 — NTDRow와 동일 규칙 공유 위해 static helper.
    /// pending 상태에서는 ntdRelevantOccurrenceDate + ntdState로 시간 진행 판정.
    static func ntdIconStyle(for item: Item, now: Date, occurrenceDate: Date? = nil) -> (String, Color) {
        if item.itemStatus == .done   { return ("clock.fill", Color.accentColor) }
        if item.itemStatus == .failed { return ("clock.fill", Color.secondary) }
        // pending — occurrence별 state. occurrenceDate가 명시되면 그것 사용, 아니면 relevant 자동.
        let occDate = occurrenceDate ?? item.ntdRelevantOccurrenceDate(at: now)
        guard let occDate, let state = item.ntdState(on: occDate, now: now) else {
            return ("clock", Color.secondary)
        }
        switch state {
        case .scheduled:  return ("clock", Color.secondary)
        case .inProgress: return ("clock", Color.accentColor)
        case .ended:      return ("clock.fill", Color.accentColor)
        }
    }

    // MARK: - completion

    private var isNTD: Bool { item.itemKind == .notTodo }
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

        // 신규 체크. Todo + 미래 일정이면 사유 시트로 분기.
        if !isNTD && isFutureSchedule(now: now) {
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
    /// - Todo: 카테고리 color
    /// - 목표(절제/활동): Item.iconColorHex (사용자 지정 color)
    /// 매칭 안 되면 nil (bar 안 보임).
    private var categoryBarColor: Color? {
        if item.itemKind.isGoal {
            guard let raw = item.iconColorHex,
                  let cc = CategoryColor(rawValue: raw)
            else { return nil }
            return cc.color
        }
        guard let cat = item.category,
              let raw = cat.colorHex,
              let cc = CategoryColor(rawValue: raw)
        else { return nil }
        return cc.color
    }

    // MARK: - status icons

    private var hasReminders: Bool {
        guard let set = item.reminders as? Set<Reminder> else { return false }
        return !set.isEmpty
    }

    private var hasAnyStatusIconOrMeta: Bool {
        if hasChecklistDisplay { return true }
        if item.itemPriority != .none { return true }
        if streakValue != nil { return true }
        if hasReminders { return true }
        if recurrenceText != nil { return true }
        if ntdDurationText != nil { return true }
        return false
    }

    /// 순서: 깃발 / 체크리스트 칩 / streak / 알림 / 반복 / NTD 목표 시간.
    /// today·list 모드 공통 — 항목의 메타 정보를 일관되게 노출.
    /// 깃발이 제일 앞 — 우선순위가 가장 중요한 식별 정보.
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
            // NTD 목표 시간 — clock 아이콘 + duration 텍스트 (반복과 별도).
            if let d = ntdDurationText {
                HStack(spacing: 2) {
                    Image(systemName: "clock")
                    Text(verbatim: d)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var streakValue: Int? {
        guard isRoutine else { return nil }
        let s = item.currentStreak(referenceDate: referenceDate)
        return s > 0 ? s : nil
    }

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
        // NTD는 별도 라벨 — 통일 원칙 적용 안 함. 카운트다운 라벨은 mode 무관 동일.
        if isNTD {
            return ntdListLabel(now: now)
        }
        // Todo (1회성/기간/반복) — 통일 원칙 적용.
        return todoUnifiedLabel(now: now)
    }

    /// 반복 패턴 요약 — repeat 아이콘과 함께 statusIcons에 표시. 없으면 nil.
    private var recurrenceText: String? {
        guard let rule = item.recurrenceRule else { return nil }
        return rule.summaryText()
    }

    /// NTD 목표 시간 텍스트 — duration 설정 시에만 노출. 미설정은 메타 라인에서 생략.
    private var ntdDurationText: String? {
        guard isNTD, let h = item.ntdDurationHourInt else { return nil }
        return formatDuration(hours: h)
    }

    /// "16h", "1d 8h", "2d" 같은 짧은 duration 표기 — NTD 메타 라인용.
    private func formatDuration(hours total: Int) -> String {
        let days = total / 24
        let rem = total % 24
        if days > 0 && rem > 0 {
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.duration.day_format", comment: ""), days
            ) + " " + String.localizedStringWithFormat(
                NSLocalizedString("ntd.duration_format", comment: ""), rem
            )
        }
        if days > 0 {
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.duration.day_format", comment: ""), days
            )
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("ntd.duration_format", comment: ""), rem
        )
    }

    // MARK: NTD label
    private func ntdListLabel(now: Date) -> String? {
        // 완료/포기(1회성): 실제 완료/포기 일시(시:분) 표시. occurrence = item.startDate.
        if item.recurrenceRule == nil,
           (item.itemStatus == .done || item.itemStatus == .failed) {
            let occDate = item.startDate ?? Date().calendarDateAnchor
            guard let inst = item.ntdLastCompletionInstant(on: occDate) ?? item.completedAt else {
                return nil
            }
            let key = (item.itemStatus == .failed) ? "ntd.label.failed_at_format" : "ntd.label.done_at_format"
            return String.localizedStringWithFormat(
                NSLocalizedString(key, comment: ""),
                NTDRow.completionTimeText(instant: inst, occurrenceDate: occDate)
            )
        }
        // pending: 다음 occurrence 상태
        guard let occurrenceDate = item.ntdRelevantOccurrenceDate(at: now),
              let state = item.ntdState(on: occurrenceDate, now: now) else {
            return nil
        }
        // 목록 탭 + 미래 일자 occurrence → Todo와 동일하게 D-N 형식.
        // ("1일 21시간 후 시작" 같은 실시간 카운트다운은 목록 탭에선 부적합 — D-day 중심 조망용)
        // 오늘 occurrence는 그대로 countdown(시작/종료 시간) 유지 — 활성 정보가 가치 있음.
        if mode == .list, occurrenceDate > .todayCalendarAnchor {
            let days = Calendar.gmt.dateComponents([.day], from: .todayCalendarAnchor, to: occurrenceDate).day ?? 0
            return formatDDay(days)
        }
        switch state {
        case .scheduled:
            guard let start = item.ntdStartInstant(on: occurrenceDate) else { return nil }
            let remaining = Int(start.timeIntervalSince(now))
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.list.starts_in_format", comment: ""),
                Item.formatNTDDuration(seconds: max(0, remaining))
            )
        case .inProgress:
            if let end = item.ntdEndInstant(on: occurrenceDate) {
                let remaining = Int(end.timeIntervalSince(now))
                return String.localizedStringWithFormat(
                    NSLocalizedString("ntd.list.remaining_format", comment: ""),
                    Item.formatNTDDuration(seconds: max(0, remaining))
                )
            }
            // 목표 미설정 → 경과
            guard let start = item.ntdStartInstant(on: occurrenceDate) else { return nil }
            let elapsed = Int(now.timeIntervalSince(start))
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.list.in_progress_format", comment: ""),
                Item.formatNTDDuration(seconds: max(0, elapsed))
            )
        case .ended:
            return nil
        }
    }

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
            let occDate = item.startDate ?? inst.calendarDateAnchor
            let key = (item.itemStatus == .failed) ? "todo.label.cancelled_at_format" : "todo.label.done_at_format"
            return String.localizedStringWithFormat(
                NSLocalizedString(key, comment: ""),
                NTDRow.completionTimeText(instant: inst, occurrenceDate: occDate)
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

    private func formatDDay(_ days: Int) -> String {
        if days == 0 { return "D-day" }
        if days > 0  { return "D-\(days)" }
        return "D+\(-days)"
    }

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
