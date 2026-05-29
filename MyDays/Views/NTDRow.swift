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
    let occurrenceDate: Date  // UTC anchor
    /// compact 표시 — 그룹 내 마지막이 아닌 row용. notes/statusIcons 숨김.
    /// (x) 버튼은 compactMode 무관 cancelMode 기준으로 표시.
    var compactMode: Bool = false

    @Environment(\.managedObjectContext) private var context
    @Environment(\.cancelMode) private var cancelMode
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

            HStack(alignment: .top, spacing: 12) {
                leadingIcon(completed: completed, failed: failed)
                    .padding(.top, 1)

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
                        trailingDisplay(now: now, completed: completed, failed: failed)
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

                // 포기 버튼 — 취소 모드 + 미완료 미포기일 때만 노출.
                // 평시엔 숨김 (사용자 의도: 우발 액션 방지, 모드 진입 후 명시적 조작).
                if cancelMode && !completed && !failed {
                    Button {
                        showGiveUpSheet = true
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 1)
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

    // MARK: - streak

    private var streakValue: Int? {
        guard item.recurrenceRule != nil else { return nil }
        let s = item.currentStreak()
        return s > 0 ? s : nil
    }

    /// 카테고리 색 — 제목 앞 세로 bar (ItemRow와 동일 규칙). 없으면 nil.
    private var categoryBarColor: Color? {
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

    /// title 옆 trailing 영역에 표시할 내용:
    /// - 진행 중(.inProgress): progress capsule (fill bar + 카운트다운 글자 overlay)
    /// - 시작 전/완료/포기: plain text (기존 trailingText 그대로)
    @ViewBuilder
    private func trailingDisplay(now: Date, completed: Bool, failed: Bool) -> some View {
        if !completed, !failed,
           let state = item.ntdState(on: occurrenceDate, now: now),
           state == .inProgress {
            progressCapsule(now: now)
        } else {
            Text(verbatim: trailingText(now: now, completed: completed, failed: failed))
                .font(.caption)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
        }
    }

    /// 진행 중 NTD의 progress capsule.
    /// - 배경: systemGray5 capsule (고정폭)
    /// - 채움: accent.opacity(0.35) capsule, leading부터 progress 비율
    /// - 글자: 카운트다운(`남음`/`경과`) 중앙 overlay
    /// progress 계산:
    /// - duration 설정: elapsed / total
    /// - duration 미설정: elapsed / 30일 cap (위젯 progressArc과 동일)
    /// 최소 가시 폭 4pt — progress > 0이면 매우 낮아도 약간 보이게.
    @ViewBuilder
    private func progressCapsule(now: Date) -> some View {
        let progress = trailingProgressValue(now: now)
        let text = countdownText(now: now)
        ZStack(alignment: .trailing) {
            Capsule()
                .fill(Color(.systemGray5))
            GeometryReader { geo in
                let fullWidth = geo.size.width
                let target = fullWidth * CGFloat(progress)
                let fillWidth: CGFloat = progress > 0 ? max(4, target) : 0
                Capsule()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: fillWidth)
            }
            .clipShape(Capsule())
            Text(verbatim: text)
                // 라이트: accent semibold (black은 fill 따뜻한 톤과 부딪혀 어색)
                // 다크: white(.primary) — fill 위에서 가장 또렷 (accent는 어두워 묻힘)
                .font(.caption.weight(.semibold))
                .foregroundStyle(colorScheme == .dark ? Color.primary : Color.accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.trailing, 8)
        }
        .frame(width: 140, height: 22)
        .layoutPriority(1)
    }

    /// trailing capsule용 progress 값 (0~1). 진행 중에만 호출 가정.
    /// - duration 있음: elapsed / total
    /// - duration 없음: elapsed / 30일 cap (위젯 progressArc과 동일 정책)
    private func trailingProgressValue(now: Date) -> Double {
        guard let start = item.ntdStartInstant(on: occurrenceDate) else { return 0 }
        let elapsed = now.timeIntervalSince(start)
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
        if item.recurrenceRule != nil {
            if let record = item.routineRecord(on: occurrenceDate), record.done {
                return true
            }
        } else if item.itemStatus == .done {
            return true
        }
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
        // 4-state 색·fill (ItemRow.ntdIconStyle과 동일 규칙):
        //   진행 전(scheduled):  clock outline + secondary
        //   진행 중(inProgress): clock outline + accent
        //   완료(done/auto-ended): clock.fill + accent
        //   포기(failed):         clock.fill + secondary
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
