import CoreData
import SwiftUI

// MARK: - NTD 행
//
// TodayView "진행 중인 절제 목표" 섹션의 NTD 한 줄.
//
// 레이아웃:
//   [clock icon] [title]                     [countdown / 상태]  [(x) 포기 버튼]
//                    [메모 (옵션)]
//                    [🔥 streak (옵션)]
//
// - leading icon: display only (탭 X). 상태에 따라 clock / clock.fill / hand.raised.fill.
// - trailing (x): pending/inProgress occurrence에서만 노출. 탭 → NTDGiveUpSheet (사유 chip + 자유 입력).
// - completed/failed occurrence는 (x) 숨김 — 추가 행동 없음.
//
// 1초 갱신은 TimelineView로 row 전체 감쌈. 상태 전이 (예: 진행 중 → 종료) 즉시 반영.

struct NTDRow: View {

    @ObservedObject var item: Item
    let occurrenceDate: Date  // UTC anchor — occurrence의 시작 calendar date
    /// 이 row가 표시되는 view date (UTC anchor). multi-day occurrence가 여러 일자에 걸쳐 노출되는 경우
    /// 어느 일자의 row인지 구분하는 용도. 미지정 시 occurrenceDate를 사용 (단일 일자 occurrence).
    /// 정책: (x) 포기 버튼은 displayedDate == 오늘인 row에서만 노출 — 어제 시작 + 오늘 진행 중인
    /// multi-day occurrence가 어제·오늘 두 row 모두 보일 때, 액션은 오늘 row에서만 받음.
    var displayedDate: Date? = nil
    /// compact 표시 — 그룹 내 마지막이 아닌 row용. notes/statusIcons 숨김.
    /// (x) 버튼은 compactMode 무관 cancelMode 기준으로 표시.
    var compactMode: Bool = false

    @Environment(\.managedObjectContext) private var context
    @Environment(\.cancelMode) private var cancelMode
    @Environment(\.itemPickerMode) private var itemPickerMode
    @Environment(\.pickedItemID) private var pickedItemID
    @Environment(\.colorScheme) private var colorScheme
    @State private var showGiveUpSheet = false

    var body: some View {
        // Adaptive schedule — target 임박 시 1초, 평소 60초로 가변. 배터리 saving.
        let schedule = AdaptiveCountdownSchedule { now in
            item.nextCountdownInstant(viewDate: occurrenceDate, now: now)
        }
        TimelineView(schedule) { context in
            let now = context.date
            let completed = isCompleted(now: now)
            let failed = isFailed()

            // .firstTextBaseline — leading icon(title3 SF Symbol)이 title 텍스트(body)의 baseline에 정렬. ItemRow와 동일.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // 항목 선택 모드 — 모든 row 앞에 checkmark slot 예약. ItemRow와 동일 시각.
                if itemPickerMode {
                    let isPicked = (pickedItemID != nil && pickedItemID == item.id)
                    Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isPicked ? Color.accentColor : Color.secondary.opacity(0.4))
                        .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }
                }
                leadingIcon(completed: completed, failed: failed)
                    // SF Symbol baseline이 text baseline과 미세히 어긋나 icon이 살짝 위로 보임 — 2pt 내려서 시각 중심 보정.
                    .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let categoryBarColor {
                            Rectangle()
                                .fill(categoryBarColor)
                                .frame(width: 3, height: 14)
                                // ItemRow와 동일 패턴 — baseline anchor를 height의 80% 위치로 옮겨 텍스트 센터 정렬.
                                .alignmentGuide(.firstTextBaseline) { d in d.height * 0.9 }
                        }
                        Text(item.title ?? "")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        // 미래 일자엔 trailing(progress/countdown) 숨김 — 활동(+)/습관(체크)과 일관성.
                        // 다른 type들은 미래 trailing 인터랙션을 숨기는데 NTD만 countdown("1일 11시간 후")을
                        // 보여주던 게 일관성 떨어짐 → 같은 정책 적용. 오늘/과거는 그대로.
                        // cancelMode에선 trailing 전체 숨김. itemPickerMode에선 progress만 노출 — 활동/집중과 일관성 (display는 유지, 액션만 숨김).
                        if (occurrenceDate <= .todayCalendarAnchor || completed || failed) && !cancelMode {
                            // trailing + (x)/check/nosign 사이 간격은 activity (progress + (+)) 패턴과 동일 4pt.
                            HStack(spacing: 4) {
                                trailingDisplay(now: now, completed: completed, failed: failed)
                                // 우측 status/action 아이콘 — displayedDate=오늘인 row에서만 노출.
                                // itemPickerMode에선 액션/아이콘 숨김 (display는 유지).
                                if isActionableDisplayedDate && !itemPickerMode {
                                    trailingStatusIcon(completed: completed, failed: failed)
                                }
                            }
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
                }
            }
            .contentShape(Rectangle())
        }
        .sheet(isPresented: $showGiveUpSheet) {
            NTDGiveUpSheet(
                descriptionText: giveUpDescription(now: Date()),
                onConfirm: { comment in
                    giveUp(comment: comment)
                }
            )
        }
    }

    // MARK: - scheduled label

    /// 시작 전 capsule overlay 라벨 — "X시 시작" / "5:00 PM 시작" (시스템 12h/24h).
    /// `todo.list.today_start_format` 키 재활용 (할일과 동일 패턴).
    private var scheduledStartLabel: String {
        let h = item.startHourInt
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("j")
        var comps = DateComponents()
        comps.hour = h
        comps.minute = 0
        let hourText = Calendar.current.date(from: comps).map(formatter.string(from:)) ?? "\(h)"
        return String.localizedStringWithFormat(
            NSLocalizedString("todo.list.today_start_format", comment: ""),
            hourText
        )
    }

    // MARK: - action eligibility

    /// 이 row가 액션(포기 (x)) 받을 수 있는 displayedDate인지.
    /// - displayedDate 미지정: occurrenceDate 사용 (단일 일자 occurrence)
    /// - 지정: displayedDate가 오늘이어야 액션 가능 (multi-day는 오늘 row에서만)
    private var isActionableDisplayedDate: Bool {
        let day = displayedDate ?? occurrenceDate
        return Calendar.gmt.isDate(day, inSameDayAs: .todayCalendarAnchor)
    }

    /// trailing status/action 아이콘 — 미완료(=interactive 포기 버튼), 완료/포기(=display only 아이콘).
    /// 정책: 진행 중은 line(outline), 완료시는 filled.
    @ViewBuilder
    private func trailingStatusIcon(completed: Bool, failed: Bool) -> some View {
        if completed {
            // 완료 → filled
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(goalAccentColor)
                .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }
        } else if failed {
            // 포기 → nosign (filled 변형 없음). 종결 상태 시각.
            Image(systemName: "nosign")
                .font(.title3)
                .foregroundStyle(goalAccentColor)
                .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 2 }
        } else {
            // 미완료/미포기 진행 중 — 포기 액션 버튼 (line, outline).
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

    // MARK: - streak

    private var streakValue: Int? {
        guard item.recurrenceRule != nil else { return nil }
        let s = item.currentStreak()
        return s > 0 ? s : nil
    }

    /// 제목 앞 세로 bar 색상. NTDRow는 목표 전용이므로 Item.iconColorHex 사용.
    /// 카테고리 미사용 정책(목표는 카테고리 없음) — legacy 카테고리 데이터는 fallback으로 사용.
    private var categoryBarColor: Color? {
        if let raw = item.iconColorHex,
           let cc = CategoryColor(rawValue: raw) {
            return cc.color
        }
        guard let cat = item.category,
              let raw = cat.colorHex,
              let cc = CategoryColor(rawValue: raw)
        else { return nil }
        return cc.color
    }

    // MARK: - status icons (ItemRow와 동일 패턴 — 알림·반복·목표 시간 메타)

    private var hasReminders: Bool {
        guard let set = item.reminders as? Set<Reminder> else { return false }
        return !set.isEmpty
    }

    private var recurrenceText: String? {
        guard let rule = item.recurrenceRule else { return nil }
        return rule.summaryText()
    }

    /// NTD 목표 시간 텍스트 — duration 설정 시 "16h"/"1d 8h" 등.
    private var ntdDurationText: String? {
        guard let h = item.ntdDurationHourInt else { return nil }
        return formatDuration(hours: h)
    }

    private var hasAnyStatusIconOrMeta: Bool {
        if streakValue != nil { return true }
        if hasReminders { return true }
        if recurrenceText != nil { return true }
        if ntdDurationText != nil { return true }
        return false
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

    /// "16h", "1d 8h", "2d" — NTD 목표 시간 짧은 표기.
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

    // MARK: - trailing 영역 (progress capsule 또는 plain text)

    /// title 옆 trailing 영역에 표시할 내용. 활동(activity) progress 패턴과 일관성:
    /// - **시작 전(.scheduled)**: plain text ("X시간 후 시작") — 0% bar는 misleading해서 텍스트만
    /// - **진행 중(.inProgress)**: progress capsule (fill 0~100% + 카운트다운 글자)
    /// - **완료**: progress capsule (full bar + "목표 달성")
    /// - **포기**: progress capsule (포기 시점까지의 진행률 + "포기")
    ///   - 포기 시각은 활동 기록에서 확인 가능 — capsule에는 표시 안 함
    @ViewBuilder
    private func trailingDisplay(now: Date, completed: Bool, failed: Bool) -> some View {
        let goalColor = goalAccentColor
        if completed {
            // 목표 달성 — full bar + "목표 달성" 텍스트.
            progressCapsule(
                progress: 1.0,
                text: String(localized: "ntd.countdown.ended"),
                goalColor: goalColor
            )
        } else if failed {
            // 포기 — 포기 시점까지의 진행률 + "포기" 텍스트.
            let giveUpInstant = item.ntdLastCompletionInstant(on: occurrenceDate) ?? now
            progressCapsule(
                progress: progressValue(at: giveUpInstant),
                text: String(localized: "ntd.countdown.failed"),
                goalColor: goalColor
            )
        } else if let state = item.ntdState(on: occurrenceDate, now: now), state == .inProgress {
            // 진행 중 — 현재 시점 progress + 카운트다운.
            progressCapsule(
                progress: progressValue(at: now),
                text: countdownText(now: now),
                goalColor: goalColor
            )
        } else {
            // 시작 전(.scheduled) — empty progress bar + "X시 시작" 텍스트 (통일성).
            progressCapsule(
                progress: 0,
                text: scheduledStartLabel,
                goalColor: goalColor
            )
        }
    }

    /// progress capsule renderer — (progress, text, color)를 받아 일관된 시각 출력.
    /// - 배경: systemGray5 capsule (고정폭)
    /// - 채움: goalColor.opacity(0.22), leading부터 progress 비율
    /// - 글자: 중앙 overlay (라이트=goalColor, 다크=white)
    /// - 최소 가시 폭 4pt — progress > 0이면 매우 낮아도 약간 보이게
    @ViewBuilder
    private func progressCapsule(progress: Double, text: String, goalColor: Color) -> some View {
        ZStack(alignment: .trailing) {
            Capsule()
                .fill(Color(.systemGray5))
            GeometryReader { geo in
                let fullWidth = geo.size.width
                let target = fullWidth * CGFloat(progress)
                let fillWidth: CGFloat = progress > 0 ? max(4, target) : 0
                Capsule()
                    .fill(goalColor.opacity(0.22))
                    .frame(width: fillWidth)
            }
            .clipShape(Capsule())
            Text(verbatim: text)
                // 라이트: goalColor semibold (black은 fill 따뜻한 톤과 부딪혀 어색)
                // 다크: white(.primary) — fill 위에서 가장 또렷 (goalColor는 어두워 묻힘)
                .font(.caption.weight(.semibold))
                .foregroundStyle(colorScheme == .dark ? Color.primary : goalColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.trailing, 8)
        }
        .frame(width: 130, height: 22)
        .layoutPriority(1)
    }

    /// 목표 아이콘 색 (iconColorHex → Color). 미설정 시 accent fallback.
    /// progress capsule 색 통일에 사용.
    private var goalAccentColor: Color {
        guard let raw = item.iconColorHex,
              let cc = CategoryColor(rawValue: raw) else {
            return Color.accentColor
        }
        return cc.color
    }

    /// trailing capsule용 progress 값 (0~1). 임의 instant 기준 — 진행 중(now)/포기(giveUpInstant) 둘 다 사용.
    /// - duration 있음: elapsed / total
    /// - duration 없음: elapsed / 30일 cap (위젯 progressArc과 동일 정책)
    private func progressValue(at instant: Date) -> Double {
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

    // MARK: - 상태 판정

    private func isCompleted(now: Date) -> Bool {
        // 명시적 포기(record.failed / status.failed)면 시간 기반 fallback 무시 — 포기 상태 보존.
        // 이전엔 .ended 시간 기반만 검사해 포기된 과거 NTD가 "목표 달성"으로 잘못 표시됐음.
        if isFailed() { return false }
        if item.recurrenceRule != nil {
            if let record = item.routineRecord(on: occurrenceDate), record.done {
                return true
            }
        } else if item.itemStatus == .done {
            return true
        }
        // Fallback: 명시 record/status 없는데 시간 지남 → 자동 완료 간주.
        // (completeFinishedNTDs가 일반적으로 record를 만들지만 transient 케이스 대비)
        return item.ntdState(on: occurrenceDate, now: now) == .ended
    }

    private func isFailed() -> Bool {
        if item.recurrenceRule != nil {
            if let record = item.routineRecord(on: occurrenceDate), record.failed {
                return true
            }
            return false
        }
        return item.itemStatus == .failed
    }

    // MARK: - leading icon

    @ViewBuilder
    private func leadingIcon(completed: Bool, failed: Bool) -> some View {
        // 목표 (goalIcon + goalColor 지정됨)이면 사용자 지정 아이콘 + 4-state 색 패턴.
        // legacy NTD (iconName 미설정)는 기존 clock 패턴 fallback.
        if let icon = item.iconName.flatMap(GoalIcon.init(rawValue:)) {
            goalLeadingIcon(icon: icon, completed: completed, failed: failed)
        } else {
            legacyClockIcon(completed: completed, failed: failed)
        }
    }

    /// 목표 사용자 지정 아이콘 — 4-state 시각 (ItemRow.goalLeadingIcon과 동일 규칙).
    /// scheduled = 회색 outline circle + 회색 icon.
    /// 크기: 20×20 (Todo 체크박스 시각 균형). icon 11pt.
    @ViewBuilder
    private func goalLeadingIcon(icon: GoalIcon, completed: Bool, failed: Bool) -> some View {
        let color = item.iconColorHex.flatMap { CategoryColor(rawValue: $0) }?.color ?? .secondary
        let style: (background: Color, iconColor: Color, border: Color, borderWidth: CGFloat) = {
            if completed {
                return (color, .white, .clear, 0)
            }
            if failed {
                return (Color(.systemGray3), .white, .clear, 0)
            }
            // pending — occurrence state 판정
            let now = Date()
            let state = item.ntdState(on: occurrenceDate, now: now) ?? .scheduled
            switch state {
            case .inProgress: return (.clear, color, color, 1)        // goalColor outline + icon
            case .ended:      return (color, .white, .clear, 0)
            case .scheduled:  return (.clear, .secondary, .secondary, 1)  // gray outline + icon
            }
        }()
        ZStack {
            Circle()
                .fill(style.background)
                .overlay(Circle().strokeBorder(style.border, lineWidth: style.borderWidth))
                .frame(width: 20, height: 20)
            Image(systemName: icon.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style.iconColor)
        }
        // SF Symbol Image와 시각 baseline 매칭 — ItemRow.goalLeadingIcon과 동일 offset 보정.
        .offset(y: -3)
    }

    /// legacy NTD(iconName 없음) — 기존 4-state clock 패턴:
    ///   진행 전(scheduled):  clock outline + secondary
    ///   진행 중(inProgress): clock outline + accent
    ///   완료(done/auto-ended): clock.fill + accent
    ///   포기(failed):         clock.fill + secondary
    @ViewBuilder
    private func legacyClockIcon(completed: Bool, failed: Bool) -> some View {
        let now = Date()
        let style: (String, Color) = {
            if failed    { return ("clock.fill", Color.secondary) }
            if completed { return ("clock.fill", Color.accentColor) }
            return ItemRow.ntdIconStyle(for: item, now: now, occurrenceDate: occurrenceDate)
        }()
        Image(systemName: style.0)
            .font(.title3)
            .foregroundStyle(style.1)
    }

    // MARK: - trailing text

    private func trailingText(now: Date, completed: Bool, failed: Bool) -> String {
        // 완료/포기 — 실제 일시 표시. occurrence별 RC.completedAt 또는 (1회성) Item.completedAt.
        // instant 없으면 fallback ("목표 달성"/"포기됨") — 자동 ended 상태 + 기록 안 된 transient.
        if completed || failed {
            if let inst = item.ntdLastCompletionInstant(on: occurrenceDate) {
                let key = failed ? "ntd.label.failed_at_format" : "ntd.label.done_at_format"
                return String.localizedStringWithFormat(
                    NSLocalizedString(key, comment: ""),
                    Self.completionTimeText(instant: inst, occurrenceDate: occurrenceDate)
                )
            }
            return failed
                ? String(localized: "ntd.countdown.failed")
                : String(localized: "ntd.countdown.ended")
        }
        return countdownText(now: now)
    }

    /// 완료/포기 일시 라벨 — 항상 일자+시:분 형식 ("5/24 14:32" 또는 "5월 24일 오후 2:32").
    /// 다일 occurrence(예: 5/22~5/25 단식)에서 어느 날 종료/포기했는지 식별을 위해 일자 항상 포함.
    static func completionTimeText(instant: Date, occurrenceDate: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("Mdjm")
        return formatter.string(from: instant)
    }

    private func countdownText(now: Date) -> String {
        guard let state = item.ntdState(on: occurrenceDate, now: now) else { return "" }
        switch state {
        case .scheduled:
            guard let start = item.ntdStartInstant(on: occurrenceDate) else { return "" }
            let remaining = Int(start.timeIntervalSince(now))
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.countdown.in_future", comment: ""),
                Item.formatNTDDuration(seconds: remaining)
            )
        case .inProgress:
            if let end = item.ntdEndInstant(on: occurrenceDate) {
                let remaining = Int(end.timeIntervalSince(now))
                return String.localizedStringWithFormat(
                    NSLocalizedString("ntd.countdown.remaining", comment: ""),
                    Item.formatNTDDuration(seconds: max(0, remaining))
                )
            } else {
                guard let start = item.ntdStartInstant(on: occurrenceDate) else { return "" }
                let elapsed = Int(now.timeIntervalSince(start))
                return String.localizedStringWithFormat(
                    NSLocalizedString("ntd.countdown.elapsed", comment: ""),
                    Item.formatNTDDuration(seconds: max(0, elapsed))
                )
            }
        case .ended:
            return String(localized: "ntd.countdown.ended")
        }
    }

    // MARK: - 포기 처리
    //
    // 1회성·반복 모두 RoutineCompletion(failed=true).comment=사유로 통일 — 1회성↔반복 전환 시 보존.
    // 1회성은 추가로 Item.status=failed + completedAt=now (ListView 완료 섹션 노출).

    /// NTDGiveUpSheet 상단 설명 문구.
    /// - 목표 시간 있음: "목표 완료까지 X 남았습니다. 정말로 포기하시겠습니까?"
    /// - 목표 시간 없음: "현재 X 진행하셨습니다. 정말로 포기하시겠습니까?"
    /// 시트가 떠 있는 동안은 갱신 안 함 (사용자 결정 시점의 스냅샷).
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
        // 포기 사유는 per-occurrence 개념 → 1회성·반복 모두 RoutineCompletion에 기록.
        // 이렇게 통일하면 1회성 NTD가 나중에 반복으로 변환되어도 기존 기록이 그대로 보존됨.
        // ItemEvent.note는 activity log timeline 용도로 함께 기록.
        let comp = RoutineCompletion(context: context)
        comp.id = UUID()
        comp.date = Calendar.gmt.startOfDay(for: occurrenceDate)
        comp.done = false
        comp.failed = true
        comp.comment = comment
        comp.completedAt = now  // 포기 시점(instant) 기록 — 활동 기록의 시간 표시.
        comp.item = item
        item.updatedAt = now

        // 1회성 NTD는 rule 자체가 종료 — Item.status도 failed로 (ListView 완료 섹션 노출).
        // OS 알림도 모두 취소 (시작 알림이 아직 fire 안 했을 수 있음).
        if item.recurrenceRule == nil {
            item.itemStatus = .failed
            item.completedAt = now
            item.cancelAllNotifications()
        } else {
            // 반복 NTD: 그 occurrence만 알림 cancel (다음 occurrence는 유지).
            // 이미 fire된 시작 알림은 영향 없음. 미래 종료 알림이 "성공"으로 fire되는 버그 방지.
            item.cancelNotifications(forOccurrence: occurrenceDate)
        }
        ItemEvent.log(.failed, on: item, in: context, note: comment)
        // 완료/취소와 동일한 animation 정책 — row 제거·재배치를 부드럽게.
        do {
            try withAnimation(.easeInOut(duration: 0.35)) {
                try context.save()
            }
        } catch {
            assertionFailure("NTD give-up save failed: \(error)")
        }
    }
}
