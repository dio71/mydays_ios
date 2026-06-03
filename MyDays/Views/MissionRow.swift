import CoreData
import SwiftUI

// MARK: - MissionRow (목표 4-type 통합 row)
//
// Phase 1: 신규 추가. 호출 위치는 아직 교체 안 함 (기존 ItemRow/NTDRow 그대로 살아있음).
// 통합 대상: 절제(NTD) / 활동(activity) / 집중(focus) / 습관(habit).
//
// 멘탈 모델: "할일은 ItemRow / 목표는 MissionRow" — 코드 구조도 같은 축으로 분리.
// 기존 ItemRow에 흩어진 goal 분기 + NTDRow를 한 곳에 통합 → 가독성·유지보수 비용 절감.
//
// 공통:
//   - 사용자 지정 iconName + iconColorHex → 4-state goalLeadingIcon (scheduled/inProgress/done/failed)
//   - 제목 앞 세로 bar = iconColorHex (목표는 카테고리 미사용)
//   - statusIcons: 🔥streak / bell(reminder) / repeat 요약 / NTD clock 시간 (kind별 분기)
//   - compactMode: 그룹 routine 비-last row에서 notes/statusIcons + trailing 액션 숨김
//   - picker/cancel mode environment 대응
//
// kind별:
//   - 절제(.notTodo): TimelineView(AdaptiveCountdownSchedule) — 카운트다운 progress capsule + (x) 포기 버튼
//   - 활동(.activity): progress capsule (valueRecorded/target) + (+N) manual / heart auto-source
//   - 집중(.focus): progress capsule (분 단위) + ▶ start 버튼 → FocusSessionView
//   - 습관(.habit): trailing square / checkmark.square.fill 체크 박스
//
// 단순화된 API:
//   - `occurrenceDate`: 1회성 = item.startDate, 반복 = occurrence start day (UTC anchor)
//   - `displayedDate`: multi-day NTD row 표시 일자. nil = occurrenceDate 사용
//   - `compactMode`: 그룹 내 비-last row
//
// Phase 2: TodayView.goalRow / ListView 목표 그룹 등 호출 위치를 MissionRow로 교체.
// Phase 3: ItemRow에서 goal 관련 코드 제거 + NTDRow 파일 삭제.

struct MissionRow: View {

    @ObservedObject var item: Item
    let occurrenceDate: Date
    var displayedDate: Date? = nil
    var compactMode: Bool = false
    /// today 모드: 진행 중 카운트다운/progress + 액션 버튼 노출. list 모드: 액션·progress 숨김 (D-day 조망용).
    var mode: DisplayMode = .today

    enum DisplayMode { case today, list }

    @Environment(\.managedObjectContext) private var context
    @Environment(\.cancelMode) private var cancelMode
    @Environment(\.itemPickerMode) private var itemPickerMode
    @Environment(\.pickedItemID) private var pickedItemID
    @Environment(\.colorScheme) private var colorScheme

    @State private var showGiveUpSheet = false
    @State private var presentFocusSession = false

    var body: some View {
        Group {
            switch item.itemKind {
            case .notTodo:
                ntdBody
            case .activity, .focus, .habit:
                nonNTDBody
            default:
                // Todo는 ItemRow가 처리. defensive fallback.
                EmptyView()
            }
        }
        .sheet(isPresented: $showGiveUpSheet) {
            NTDGiveUpSheet(
                descriptionText: giveUpDescription(now: Date()),
                onConfirm: { comment in
                    giveUp(comment: comment)
                }
            )
        }
        .fullScreenCover(isPresented: $presentFocusSession) {
            FocusSessionView(item: item, occurrenceDate: occurrenceDate)
        }
    }

    // MARK: - NTD body (TimelineView with countdown)

    @ViewBuilder
    private var ntdBody: some View {
        let schedule = AdaptiveCountdownSchedule { now in
            item.nextCountdownInstant(viewDate: occurrenceDate, now: now)
        }
        TimelineView(schedule) { context in
            let now = context.date
            let completed = isNTDCompleted(now: now)
            let failed = isNTDFailed()
            rowLayout(
                trailing: AnyView(ntdTrailing(now: now, completed: completed, failed: failed))
            )
        }
    }

    // MARK: - Activity/Focus/Habit body (static rendering)

    @ViewBuilder
    private var nonNTDBody: some View {
        rowLayout(trailing: AnyView(nonNTDTrailing()))
    }

    // MARK: - 공통 row layout

    /// 모든 kind 공통 row 구조 — picker check / leading icon / title + meta + trailing.
    @ViewBuilder
    private func rowLayout(trailing: AnyView) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // 항목 선택 모드 — 모든 row 앞 checkmark slot 예약. ItemRow와 동일 시각.
            if itemPickerMode {
                let isPicked = (pickedItemID != nil && pickedItemID == item.id)
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isPicked ? Color.accentColor : Color.secondary.opacity(0.4))
                    .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }
            }
            goalLeadingIcon
                .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let categoryBarColor {
                        Rectangle()
                            .fill(categoryBarColor)
                            .frame(width: 3, height: 14)
                            .alignmentGuide(.firstTextBaseline) { d in d.height * 0.9 }
                    }
                    Text(item.title ?? "")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    // list 모드 D-day / 시각 라벨 — 제목과 오른쪽 사이.
                    if mode == .list, let label = listLabel {
                        Text(verbatim: label)
                            .font(.caption)
                            .foregroundStyle(item.isOverdue(referenceDate: occurrenceDate) ? .red : .secondary)
                            .layoutPriority(1)
                    }
                    trailing
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
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - 4-state goalLeadingIcon (kind 무관 공통)

    /// 사용자 지정 GoalIcon + iconColorHex 기반 4-state 시각.
    /// iconName 없는 legacy NTD는 clock fallback (NTDRow.legacyClockIcon와 동일 패턴).
    @ViewBuilder
    private var goalLeadingIcon: some View {
        if let icon = item.iconName.flatMap(GoalIcon.init(rawValue:)) {
            let color = item.iconColorHex.flatMap { CategoryColor(rawValue: $0) }?.color ?? .secondary
            let style = leadingIconStyle(color: color)
            ZStack {
                Circle()
                    .fill(style.background)
                    .overlay(Circle().strokeBorder(style.border, lineWidth: style.borderWidth))
                    .frame(width: 20, height: 20)
                Image(systemName: icon.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(style.iconColor)
            }
            .offset(y: -3)
        } else if item.itemKind == .notTodo {
            legacyClockIcon
        } else {
            // 활동/집중/습관에서 iconName 미설정은 비정상 — 빈 circle.
            Circle()
                .strokeBorder(Color.secondary, lineWidth: 1)
                .frame(width: 20, height: 20)
                .offset(y: -3)
        }
    }

    /// legacy NTD(iconName 없음) — 4-state clock 패턴 (NTDRow에서 이식).
    @ViewBuilder
    private var legacyClockIcon: some View {
        let now = Date()
        let completed = isNTDCompleted(now: now)
        let failed = isNTDFailed()
        let (name, color): (String, Color) = {
            if failed    { return ("clock.fill", Color.secondary) }
            if completed { return ("clock.fill", Color.accentColor) }
            // pending — occurrence state 기준
            let state = item.ntdState(on: occurrenceDate, now: now) ?? .scheduled
            switch state {
            case .inProgress: return ("clock", Color.accentColor)
            case .ended:      return ("clock.fill", Color.accentColor)
            case .scheduled:  return ("clock", Color.secondary)
            }
        }()
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(color)
    }

    private struct LeadingIconStyle {
        let background: Color
        let iconColor: Color
        let border: Color
        let borderWidth: CGFloat
    }

    /// 4-state 시각 스타일 — kind별 분기.
    /// NTD: occurrence state (scheduled/inProgress/ended) + completed/failed flag
    /// activity/focus: target 도달 여부 + 1회성 status
    /// habit: 완료/미완료 binary
    private func leadingIconStyle(color: Color) -> LeadingIconStyle {
        // 모든 kind 공통: 명시적 done이면 fill, failed면 회색 fill
        if isCompleted {
            return LeadingIconStyle(background: color, iconColor: .white, border: .clear, borderWidth: 0)
        }
        if isFailed {
            return LeadingIconStyle(background: Color(.systemGray3), iconColor: .white, border: .clear, borderWidth: 0)
        }
        // pending — kind별 progress 시각
        switch item.itemKind {
        case .notTodo:
            let state = item.ntdState(on: occurrenceDate, now: Date()) ?? .scheduled
            switch state {
            case .inProgress: return LeadingIconStyle(background: .clear, iconColor: color, border: color, borderWidth: 1)
            case .ended:      return LeadingIconStyle(background: color, iconColor: .white, border: .clear, borderWidth: 0)
            case .scheduled:  return LeadingIconStyle(background: .clear, iconColor: .secondary, border: .secondary, borderWidth: 1)
            }
        case .activity, .focus:
            // 진행 중(value > 0) → goalColor outline. 미시작 → 회색 outline.
            let hasProgress = (item.routineRecord(on: occurrenceDate)?.valueRecorded?.doubleValue ?? 0) > 0
            if hasProgress {
                return LeadingIconStyle(background: .clear, iconColor: color, border: color, borderWidth: 1)
            }
            return LeadingIconStyle(background: .clear, iconColor: .secondary, border: .secondary, borderWidth: 1)
        case .habit:
            // 습관은 binary — pending 시 회색 outline.
            return LeadingIconStyle(background: .clear, iconColor: .secondary, border: .secondary, borderWidth: 1)
        default:
            return LeadingIconStyle(background: .clear, iconColor: .secondary, border: .secondary, borderWidth: 1)
        }
    }

    // MARK: - 완료/포기 판정 (kind별)

    /// 명시적 완료 — 반복: RC.done, 1회성: Item.status=done.
    private var isCompleted: Bool {
        if item.recurrenceRule != nil {
            return item.routineRecord(on: occurrenceDate)?.done == true
        }
        return item.itemStatus == .done
    }

    /// 명시적 포기 — 반복: RC.failed, 1회성: Item.status=failed.
    private var isFailed: Bool {
        if item.recurrenceRule != nil {
            return item.routineRecord(on: occurrenceDate)?.failed == true
        }
        return item.itemStatus == .failed
    }

    /// NTD 특수 — 시간 기반 자동 ended까지 포함.
    private func isNTDCompleted(now: Date) -> Bool {
        if isFailed { return false }
        if isCompleted { return true }
        // Fallback: 시간 지남 → 자동 완료 (completeFinishedNTDs 늦은 케이스 대비).
        return item.ntdState(on: occurrenceDate, now: now) == .ended
    }

    private func isNTDFailed() -> Bool { isFailed }

    // MARK: - 제목 앞 세로 bar (iconColorHex 기반)

    /// 목표 전용 정책 — iconColorHex 우선. legacy 카테고리 데이터는 fallback.
    private var categoryBarColor: Color? {
        if let raw = item.iconColorHex, let cc = CategoryColor(rawValue: raw) {
            return cc.color
        }
        guard let cat = item.category, let raw = cat.colorHex, let cc = CategoryColor(rawValue: raw) else {
            return nil
        }
        return cc.color
    }

    // MARK: - status icons (kind 무관 공통 + NTD clock)

    // statusIcons 공용 helper — Item 확장으로 이전 (ItemRow와 공유).
    private var streakValue: Int? { item.streakValueIfRoutine(referenceDate: occurrenceDate) }
    private var hasReminders: Bool { item.hasReminders }
    private var recurrenceText: String? { item.recurrenceTextSummary }

    /// NTD 목표 시간 텍스트 — duration 설정 시 "16h"/"1d 8h" 등.
    private var ntdDurationText: String? {
        guard item.itemKind == .notTodo, let h = item.ntdDurationHourInt else { return nil }
        return formatDuration(hours: h)
    }

    private var hasAnyStatusIconOrMeta: Bool {
        streakValue != nil || hasReminders || recurrenceText != nil || ntdDurationText != nil
    }

    @ViewBuilder
    private var statusIcons: some View {
        HStack(spacing: 8) {
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

    /// NTD 목표 시간 짧은 표기 — "16h", "1d 8h".
    private func formatDuration(hours total: Int) -> String {
        let days = total / 24
        let rem = total % 24
        if days > 0 && rem > 0 {
            return String.localizedStringWithFormat(NSLocalizedString("ntd.duration.day_format", comment: ""), days)
                 + " " + String.localizedStringWithFormat(NSLocalizedString("ntd.duration_format", comment: ""), rem)
        }
        if days > 0 {
            return String.localizedStringWithFormat(NSLocalizedString("ntd.duration.day_format", comment: ""), days)
        }
        return String.localizedStringWithFormat(NSLocalizedString("ntd.duration_format", comment: ""), rem)
    }

    // MARK: - NTD trailing (progress capsule + 포기/완료 아이콘)

    /// NTDRow 동일 패턴. list 모드에선 trailing 전체 숨김 — D-day 조망용.
    @ViewBuilder
    private func ntdTrailing(now: Date, completed: Bool, failed: Bool) -> some View {
        if mode != .list && (occurrenceDate <= .todayCalendarAnchor || completed || failed) && !cancelMode {
            HStack(spacing: 4) {
                ntdProgressDisplay(now: now, completed: completed, failed: failed)
                if isActionableDisplayedDate && !itemPickerMode {
                    ntdTrailingStatusIcon(completed: completed, failed: failed)
                }
            }
        }
    }

    /// (x)/checkmark/nosign — pending=interactive 버튼 / 완료·포기=display only.
    @ViewBuilder
    private func ntdTrailingStatusIcon(completed: Bool, failed: Bool) -> some View {
        if completed {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(goalAccentColor)
                .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }
        } else if failed {
            Image(systemName: "nosign")
                .font(.title3)
                .foregroundStyle(goalAccentColor)
                .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }
        } else {
            Button {
                showGiveUpSheet = true
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.title3)
                    .foregroundStyle(goalAccentColor)
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }
        }
    }

    /// NTD progress capsule — 4-state별 progress + 텍스트.
    @ViewBuilder
    private func ntdProgressDisplay(now: Date, completed: Bool, failed: Bool) -> some View {
        let goalColor = goalAccentColor
        if completed {
            progressCapsule(progress: 1.0, text: String(localized: "ntd.countdown.ended"), goalColor: goalColor)
        } else if failed {
            let giveUpInstant = item.ntdLastCompletionInstant(on: occurrenceDate) ?? now
            progressCapsule(progress: ntdProgressValue(at: giveUpInstant), text: String(localized: "ntd.countdown.failed"), goalColor: goalColor)
        } else if let state = item.ntdState(on: occurrenceDate, now: now), state == .inProgress {
            progressCapsule(progress: ntdProgressValue(at: now), text: ntdCountdownText(now: now), goalColor: goalColor)
        } else {
            progressCapsule(progress: 0, text: ntdScheduledStartLabel, goalColor: goalColor)
        }
    }

    /// 이 row가 액션(포기 (x)) 받을 수 있는 displayedDate인지.
    private var isActionableDisplayedDate: Bool {
        let day = displayedDate ?? occurrenceDate
        return Calendar.gmt.isDate(day, inSameDayAs: .todayCalendarAnchor)
    }

    /// NTD progress 값 (elapsed / total) — duration 있음/없음 분기.
    private func ntdProgressValue(at instant: Date) -> Double {
        guard let start = item.ntdStartInstant(on: occurrenceDate) else { return 0 }
        let elapsed = instant.timeIntervalSince(start)
        if let end = item.ntdEndInstant(on: occurrenceDate) {
            let total = end.timeIntervalSince(start)
            guard total > 0 else { return 0 }
            return max(0, min(elapsed / total, 1.0))
        }
        let thirtyDays: TimeInterval = 30 * 24 * 3600
        return max(0, min(elapsed / thirtyDays, 1.0))
    }

    private var ntdScheduledStartLabel: String {
        let h = item.startHourInt
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("j")
        var comps = DateComponents()
        comps.hour = h
        comps.minute = 0
        let hourText = Calendar.current.date(from: comps).map(formatter.string(from:)) ?? "\(h)"
        return String.localizedStringWithFormat(NSLocalizedString("todo.list.today_start_format", comment: ""), hourText)
    }

    private func ntdCountdownText(now: Date) -> String {
        guard let state = item.ntdState(on: occurrenceDate, now: now) else { return "" }
        switch state {
        case .scheduled:
            guard let start = item.ntdStartInstant(on: occurrenceDate) else { return "" }
            let remaining = Int(start.timeIntervalSince(now))
            return String.localizedStringWithFormat(NSLocalizedString("ntd.countdown.in_future", comment: ""), Item.formatNTDDuration(seconds: remaining))
        case .inProgress:
            if let end = item.ntdEndInstant(on: occurrenceDate) {
                let remaining = Int(end.timeIntervalSince(now))
                return String.localizedStringWithFormat(NSLocalizedString("ntd.countdown.remaining", comment: ""), Item.formatNTDDuration(seconds: max(0, remaining)))
            } else {
                guard let start = item.ntdStartInstant(on: occurrenceDate) else { return "" }
                let elapsed = Int(now.timeIntervalSince(start))
                return String.localizedStringWithFormat(NSLocalizedString("ntd.countdown.elapsed", comment: ""), Item.formatNTDDuration(seconds: max(0, elapsed)))
            }
        case .ended:
            return String(localized: "ntd.countdown.ended")
        }
    }

    // MARK: - Activity/Focus/Habit trailing

    @ViewBuilder
    private func nonNTDTrailing() -> some View {
        let isFuture = occurrenceDate > .todayCalendarAnchor
        let notYetStarted = item.startDate.map { $0 > .todayCalendarAnchor } ?? false
        let showTrailing = mode != .list && !cancelMode && !isFuture && !notYetStarted
        if showTrailing {
            switch item.itemKind {
            case .activity: activityTrailing
            case .focus:    focusTrailing
            case .habit:    habitTrailing
            default:        EmptyView()
            }
        }
    }

    /// 활동 progress capsule + (+) 또는 heart auto-source badge.
    @ViewBuilder
    private var activityTrailing: some View {
        let target = Int(item.effectiveTargetValue(on: occurrenceDate) ?? 0)
        let current = item.activityCurrentValue(on: occurrenceDate)
        let step = Item.activityQuickStep(target: max(target, 1))
        let progress: Double = target > 0 ? min(Double(current) / Double(target), 1.0) : 0
        let goalColor = goalAccentColor
        let isAutoSource = item.activitySource != .manual
        let isPastDate = occurrenceDate < .todayCalendarAnchor
        let isDone = current >= target && target > 0
        HStack(spacing: 2) {
            progressCapsule(progress: progress, text: "\(current)/\(target)", goalColor: goalColor, monospaceDigit: true)
            if !isPastDate && !itemPickerMode {
                if isAutoSource {
                    Image(systemName: isDone ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(goalColor.opacity(0.85))
                        .frame(width: 22, alignment: .center)
                        .accessibilityLabel(Text("activity.source.auto.accessibility"))
                } else {
                    Button {
                        Item.incrementActivityValue(for: item, by: step, occurrenceDate: occurrenceDate, in: context)
                        saveContext()
                    } label: {
                        Image(systemName: isDone ? "plus.circle.fill" : "plus.circle")
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

    /// 집중 progress capsule + ▶ 시작 버튼.
    @ViewBuilder
    private var focusTrailing: some View {
        let target = Int(item.effectiveTargetValue(on: occurrenceDate) ?? 0)
        let current = Int(item.focusCurrentMinutes(on: occurrenceDate))
        let progress: Double = target > 0 ? min(Double(current) / Double(target), 1.0) : 0
        let goalColor = goalAccentColor
        let isPastDate = occurrenceDate < .todayCalendarAnchor
        let isDone = target > 0 && current >= target
        HStack(spacing: 2) {
            progressCapsule(progress: progress, text: "\(current)/\(target)", goalColor: goalColor, monospaceDigit: true)
            if !isPastDate && !itemPickerMode {
                Button {
                    presentFocusSession = true
                } label: {
                    Image(systemName: isDone ? "play.circle.fill" : "play.circle")
                        .font(.title3)
                        .foregroundStyle(goalColor)
                }
                .buttonStyle(.plain)
            }
        }
        .layoutPriority(1)
        .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }
    }

    /// 습관 trailing 체크 박스 — square / checkmark.square.fill 토글.
    @ViewBuilder
    private var habitTrailing: some View {
        if !itemPickerMode {
            let checked = isCompleted
            Button(action: toggleHabit) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }
        }
    }

    /// 모든 mission 진행도 capsule — 130×22pt 고정.
    /// - 배경: systemGray5
    /// - fill: goalColor.opacity(0.22) — progress 비율, 최소 가시 4pt
    /// - 글자: trailing 정렬 (라이트=goalColor / 다크=primary)
    /// `monospaceDigit`: activity/focus "{current}/{target}" 처럼 숫자 폭 정렬 필요할 때 true.
    @ViewBuilder
    private func progressCapsule(progress: Double, text: String, goalColor: Color, monospaceDigit: Bool = false) -> some View {
        ZStack(alignment: .trailing) {
            Capsule().fill(Color(.systemGray5))
            GeometryReader { geo in
                let fullWidth = geo.size.width
                let targetWidth = fullWidth * CGFloat(progress)
                let fillWidth: CGFloat = progress > 0 ? max(4, targetWidth) : 0
                Capsule()
                    .fill(goalColor.opacity(0.22))
                    .frame(width: fillWidth)
            }
            .clipShape(Capsule())
            Text(verbatim: text)
                .font(monospaceDigit ? .caption.weight(.semibold).monospacedDigit() : .caption.weight(.semibold))
                .foregroundStyle(colorScheme == .dark ? Color.primary : goalColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.trailing, 8)
        }
        .frame(width: 130, height: 22)
        .layoutPriority(1)
    }

    /// 목표 아이콘 색 — iconColorHex → Color. 미설정 시 accent fallback.
    private var goalAccentColor: Color {
        guard let raw = item.iconColorHex,
              let cc = CategoryColor(rawValue: raw) else {
            return Color.accentColor
        }
        return cc.color
    }

    // MARK: - 액션 (습관 toggle / NTD 포기 / context save)

    private func toggleHabit() {
        let now = Date()
        if item.recurrenceRule != nil {
            // 반복 — RC toggle.
            if let rc = item.routineRecord(on: occurrenceDate) {
                if rc.done {
                    context.delete(rc)
                } else {
                    rc.done = true
                    rc.failed = false
                    rc.completedAt = now
                }
            } else {
                let rc = RoutineCompletion(context: context)
                rc.id = UUID()
                rc.date = Calendar.gmt.startOfDay(for: occurrenceDate)
                rc.item = item
                rc.done = true
                rc.failed = false
                rc.completedAt = now
            }
        } else {
            // 1회성 — status toggle.
            if item.itemStatus == .done {
                item.itemStatus = .pending
                item.completedAt = nil
            } else {
                item.itemStatus = .done
                item.completedAt = now
            }
        }
        item.updatedAt = now
        ItemEvent.log(item.itemStatus == .done ? .completed : .uncompleted, on: item, in: context)
        saveContext()
    }

    private func saveContext() {
        guard context.hasChanges else { return }
        do {
            try withAnimation(.easeInOut(duration: 0.35)) {
                try context.save()
            }
        } catch {
            assertionFailure("MissionRow save failed: \(error)")
        }
    }

    // MARK: - list 모드 라벨 (D-day / 시각 / 완료·포기 일시)
    //
    // ItemRow의 dueDayLabel 로직 중 list 모드용을 mission 한정으로 포팅.
    // - NTD: ntdListLabel (실시간 카운트다운/D-day/완료 일시)
    // - activity/focus/habit: D-day 기반 (1회성 startDate / 반복 next occurrence)

    private var listLabel: String? {
        let now = Date()
        if item.itemKind == .notTodo {
            return ntdListLabelForList(now: now)
        }
        return goalListLabel(now: now)
    }

    /// NTD list 라벨 — ItemRow.ntdListLabel과 동일 패턴.
    private func ntdListLabelForList(now: Date) -> String? {
        // 1회성 완료/포기: 실제 일시 표시.
        if item.recurrenceRule == nil,
           (item.itemStatus == .done || item.itemStatus == .failed) {
            let occDate = item.startDate ?? Date().calendarDateAnchor
            guard let inst = item.ntdLastCompletionInstant(on: occDate) ?? item.completedAt else {
                return nil
            }
            let key = (item.itemStatus == .failed) ? "ntd.label.failed_at_format" : "ntd.label.done_at_format"
            return String.localizedStringWithFormat(
                NSLocalizedString(key, comment: ""),
                Self.completionTimeText(instant: inst)
            )
        }
        guard let occurrence = item.ntdRelevantOccurrenceDate(at: now),
              let state = item.ntdState(on: occurrence, now: now) else {
            return nil
        }
        // 미래 일자 occurrence → D-N 형식 (실시간 카운트다운은 list mode 부적합).
        if occurrence > .todayCalendarAnchor {
            let days = Calendar.gmt.dateComponents([.day], from: .todayCalendarAnchor, to: occurrence).day ?? 0
            return formatDDay(days)
        }
        switch state {
        case .scheduled:
            guard let start = item.ntdStartInstant(on: occurrence) else { return nil }
            let remaining = Int(start.timeIntervalSince(now))
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.list.starts_in_format", comment: ""),
                Item.formatNTDDuration(seconds: max(0, remaining))
            )
        case .inProgress:
            if let end = item.ntdEndInstant(on: occurrence) {
                let remaining = Int(end.timeIntervalSince(now))
                return String.localizedStringWithFormat(
                    NSLocalizedString("ntd.list.remaining_format", comment: ""),
                    Item.formatNTDDuration(seconds: max(0, remaining))
                )
            }
            guard let start = item.ntdStartInstant(on: occurrence) else { return nil }
            let elapsed = Int(now.timeIntervalSince(start))
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.list.in_progress_format", comment: ""),
                Item.formatNTDDuration(seconds: max(0, elapsed))
            )
        case .ended:
            return nil
        }
    }

    /// 활동/집중/습관 list 라벨 — 1회성 완료/포기 일시 또는 D-day.
    private func goalListLabel(now: Date) -> String? {
        // 1회성 완료/포기: completedAt 시각 표시.
        if item.recurrenceRule == nil,
           (item.itemStatus == .done || item.itemStatus == .failed),
           let inst = item.completedAt {
            let key = (item.itemStatus == .failed) ? "todo.label.cancelled_at_format" : "todo.label.done_at_format"
            return String.localizedStringWithFormat(
                NSLocalizedString(key, comment: ""),
                Self.completionTimeText(instant: inst)
            )
        }
        // 반복: 다음 occurrence 기준 D-day.
        // 주의: nextOccurrence(after:)는 `calendar.startOfDay(for: referenceDate)`로 search 시작점을 계산하는데,
        // `now`(Date instant)를 그대로 넘기면 local↔UTC offset 때문에 "어제" UTC 일자가 시작점이 되어
        // 오늘 occurrence가 어제로 잡히는 케이스 발생. `.todayCalendarAnchor`를 명시 전달해야 안전.
        if let rule = item.recurrenceRule {
            guard let next = rule.nextOccurrence(after: .todayCalendarAnchor, startDate: item.startDate, endDate: item.recurrenceEndDate) else {
                return nil
            }
            let realToday = Calendar.gmt.startOfDay(for: .todayCalendarAnchor)
            let nextDay = Calendar.gmt.startOfDay(for: next)
            let days = Calendar.gmt.dateComponents([.day], from: realToday, to: nextDay).day ?? 0
            return formatDDay(days)
        }
        // 1회성: startDate D-day.
        guard let start = item.startDate else { return nil }
        let realToday = Calendar.gmt.startOfDay(for: .todayCalendarAnchor)
        let startDay = Calendar.gmt.startOfDay(for: start)
        let days = Calendar.gmt.dateComponents([.day], from: realToday, to: startDay).day ?? 0
        return formatDDay(days)
    }

    /// 일시 → "M/d 14:32" 형식 (multi-day occurrence에서 어느 날 일어났는지 식별 위해 일자 포함).
    /// static으로 노출 — ItemRow의 Todo 완료/취소 라벨에서도 재사용 (`MissionRow.completionTimeText(instant:)`).
    static func completionTimeText(instant: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("Mdjm")
        return formatter.string(from: instant)
    }

    // formatDDay는 `Views/RowHelpers.swift`의 free 함수로 이전.

    // MARK: - NTD 포기 처리 (NTDRow에서 이식)

    private func giveUpDescription(now: Date) -> String {
        if let end = item.ntdEndInstant(on: occurrenceDate) {
            let remaining = max(0, Int(end.timeIntervalSince(now)))
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.giveup_sheet.description.with_target", comment: ""),
                Item.formatNTDDuration(seconds: remaining)
            )
        }
        guard let start = item.ntdStartInstant(on: occurrenceDate) else { return "" }
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        return String.localizedStringWithFormat(
            NSLocalizedString("ntd.giveup_sheet.description.without_target", comment: ""),
            Item.formatNTDDuration(seconds: elapsed)
        )
    }

    private func giveUp(comment: String?) {
        let now = Date()
        let comp = RoutineCompletion(context: context)
        comp.id = UUID()
        comp.date = Calendar.gmt.startOfDay(for: occurrenceDate)
        comp.done = false
        comp.failed = true
        comp.comment = comment
        comp.completedAt = now
        comp.item = item
        item.updatedAt = now

        if item.recurrenceRule == nil {
            item.itemStatus = .failed
            item.completedAt = now
            item.cancelAllNotifications()
        } else {
            item.cancelNotifications(forOccurrence: occurrenceDate)
        }
        ItemEvent.log(.failed, on: item, in: context, note: comment)
        do {
            try withAnimation(.easeInOut(duration: 0.35)) {
                try context.save()
            }
        } catch {
            assertionFailure("MissionRow give-up save failed: \(error)")
        }
    }
}
