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
    @Environment(\.managedObjectContext) private var context

    /// 루틴 체크박스 동작 여부. 목록탭은 referenceDate 컨텍스트가 명확하지 않아 비활성.
    private var routineCheckable: Bool { mode != .list }

    var body: some View {
        // Adaptive TimelineView — 시각 라벨/색상 전환을 시간 흐름에 따라 자동 갱신.
        // target 임박 시 1초/30초, 평소 60초로 가변해 배터리 saving.
        let schedule = AdaptiveCountdownSchedule { now in
            item.nextCountdownInstant(viewDate: referenceDate, now: now)
        }
        TimelineView(schedule) { _ in
            rowContent
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            leadingControl
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
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

                if let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if hasAnyStatusIconOrMeta {
                    statusIcons
                }
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - leading control

    @ViewBuilder
    private var leadingControl: some View {
        if isNTD {
            ntdStatusIcon
        } else if isRoutine && !routineCheckable {
            routineStatusIcon
        } else {
            // 체크박스 색상:
            // - 완료: 파란 fill
            // - 진행 중 (시작 instant 후 ~ 종료 instant 전): 파란 outline
            // - 그 외 (시작 전 또는 종료 후): 회색 outline
            let color: Color = isCompletedForDate
                ? Color.accentColor
                : (isInProgress ? Color.accentColor : Color.secondary)
            Button(action: toggleDone) {
                Image(systemName: isCompletedForDate ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(color)
            }
            .buttonStyle(.plain)
        }
    }

    /// 진행 중 판정 — Item.isInProgress 위임.
    private var isInProgress: Bool {
        item.isInProgress(viewDate: referenceDate, now: Date())
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
    /// - pending + 시작 전 (scheduled): stopwatch outline + secondary (회색) → 진행 전
    /// - pending + 진행 중 (inProgress): stopwatch outline + accent (파랑) → 활성
    /// - done (자동/명시 완료):           stopwatch.fill + accent (파랑) → 완료
    /// - failed (사용자 포기):            stopwatch.fill + secondary (회색 filled) → 종료/중단
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
        if item.itemStatus == .done   { return ("stopwatch.fill", Color.accentColor) }
        if item.itemStatus == .failed { return ("stopwatch.fill", Color.secondary) }
        // pending — occurrence별 state. occurrenceDate가 명시되면 그것 사용, 아니면 relevant 자동.
        let occDate = occurrenceDate ?? item.ntdRelevantOccurrenceDate(at: now)
        guard let occDate, let state = item.ntdState(on: occDate, now: now) else {
            return ("stopwatch", Color.secondary)
        }
        switch state {
        case .scheduled:  return ("stopwatch", Color.secondary)
        case .inProgress: return ("stopwatch", Color.accentColor)
        case .ended:      return ("stopwatch.fill", Color.accentColor)
        }
    }

    // MARK: - completion

    private var isNTD: Bool { item.itemKind == .notTodo }
    private var isRoutine: Bool { item.recurrenceRule != nil }

    private var isCompletedForDate: Bool {
        if isRoutine {
            return item.isCompletedForDate(referenceDate)
        }
        return item.itemStatus == .done
    }

    /// 체크 토글 — 단일/반복 통일 처리.
    /// 1) 모든 항목은 `RoutineCompletion` 레코드 생성/삭제 (per-occurrence 기록 = 활동 기록 소스)
    /// 2) 1회성은 추가로 `Item.status`를 cache로 유지 → ListView 완료 섹션 fetch에서 빠른 분류
    /// 반복은 Item.status를 .pending 그대로 (rule이 계속 진행 중이라 의미 X).
    /// RC.date 기준:
    ///   - 반복: referenceDate (그 occurrence date)
    ///   - 1회성: item.startDate (canonical event date) — 다양한 day view에서 같은 RC 매칭
    private func toggleDone() {
        let now = Date()
        let day = isRoutine
            ? Calendar.gmt.startOfDay(for: referenceDate)
            : Calendar.gmt.startOfDay(for: item.startDate ?? referenceDate)

        let completions = (item.completions as? Set<RoutineCompletion>) ?? []
        let existing = completions.first { c in
            guard let d = c.date else { return false }
            return Calendar.gmt.isDate(d, inSameDayAs: day)
        }

        let action: ItemAction
        if let existing {
            context.delete(existing)
            action = .uncompleted
            if !isRoutine {
                item.itemStatus = .pending
                item.completedAt = nil
            }
        } else {
            let comp = RoutineCompletion(context: context)
            comp.id = UUID()
            comp.date = day
            comp.done = true
            comp.completedAt = now  // 체크 instant — 활동 기록 시각 표시용
            comp.item = item
            action = .completed
            if !isRoutine {
                item.itemStatus = .done
                item.completedAt = now
            }
        }
        item.updatedAt = now
        ItemEvent.log(action, on: item, in: context)
        do {
            try context.save()
        } catch {
            assertionFailure("Toggle save failed: \(error)")
        }
    }

    // MARK: - status icons

    private var hasReminders: Bool {
        guard let set = item.reminders as? Set<Reminder> else { return false }
        return !set.isEmpty
    }

    private var hasAnyStatusIconOrMeta: Bool {
        if item.itemPriority != .none { return true }
        if streakValue != nil { return true }
        if hasReminders { return true }
        if recurrenceText != nil { return true }
        if ntdDurationText != nil { return true }
        return false
    }

    /// 순서: 깃발 / streak / 알림 / 반복 / NTD 목표 시간.
    /// today·list 모드 공통 — 항목의 메타 정보를 일관되게 노출.
    @ViewBuilder
    private var statusIcons: some View {
        HStack(spacing: 8) {
            if item.itemPriority != .none {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(flagColor(for: item.itemPriority))
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

    private func flagColor(for priority: Priority) -> Color {
        switch priority {
        case .high:   return .red
        case .medium: return .orange
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
    private func todoUnifiedLabel(now: Date) -> String? {
        guard let occStart = item.referenceOccurrenceStartDate(viewDate: referenceDate) else {
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

        // 원칙 3: 시각 라벨 (시각 설정 + 오늘이 시작/종료일)
        if hasExplicitTime {
            if isStartToday && isDueToday {
                // 시작=종료=오늘. 단일시간(s==e)이거나 시작 전 → "s시 시작". 시작 후 → "e시 종료".
                if startH == dueH {
                    return startTimeLabel(startH)
                }
                if let inst = startInst, now < inst {
                    return startTimeLabel(startH)
                }
                return endTimeLabel(dueH)
            }
            if isDueToday {
                return endTimeLabel(dueH)
            }
            if isStartToday {
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
        if !hasExplicitTime && isDueToday {
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
