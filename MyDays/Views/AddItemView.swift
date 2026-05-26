import CoreData
import SwiftUI

struct AddItemView: View {

    let editingItem: Item?

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool

    @State private var title: String
    @State private var notes: String
    // NTD/Todo 분기.
    @State private var kind: ItemKind
    @State private var hasStart: Bool
    @State private var startDate: Date
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @State private var priority: Priority
    // Todo·NTD 공통 wall-clock 시각 — non-optional Int.
    // startHour: 0~23 (default 0). dueHour: 0~24 (24 = 시간 미설정 sentinel = 다음 날 0시).
    // hasTime은 derived (`dueHour < 24`) — 별도 toggle state 불필요.
    @State private var startHour: Int
    @State private var dueHour: Int

    /// 시간 명시 여부 — derived. `dueHour < 24`면 시간 설정 ON, `== 24`면 OFF (종일).
    private var hasTime: Bool { dueHour < 24 }
    // 반복 종료일 (UTC anchor). nil = 무기한.
    @State private var recurrenceEndDate: Date?
    // NTD 전용. ntdDurationHour=nil = 미설정 = "한계까지" (반복 의미 X).
    @State private var ntdDurationHour: Int?
    // legacy: 시간대 chip은 UI에서 제거됨. Core Data 호환 위해 state는 유지 (save 시 .none 고정).
    @State private var startTimeOfDay: TimeOfDay = .none
    @State private var dueTimeOfDay: TimeOfDay = .none
    // 알림 offset (분). nil = 알림 OFF. 0 = 정시. 음수 = 사전 알림.
    @State private var ntdStartAlertOffset: Int?
    @State private var ntdEndAlertOffset: Int?
    // Todo: 시작/마감 알림 별도 — 단일 모드는 시작만, 기간 모드는 둘 다.
    @State private var todoStartAlertOffset: Int?
    @State private var todoDueAlertOffset: Int?

    /// 날짜·시각 chip 클릭 시 인라인 확장 (iOS Calendar 패턴).
    /// 날짜·시각이 별도 subchip으로 분리됐기 때문에 expansion도 calendar/time 둘로 나뉨.
    /// recurrenceEnd는 calendar 전용.
    @State private var dateExpansion: DateExpansion = .none
    /// NTD 목표 시간 row 확장 여부 (인라인 wheel).
    @State private var durationExpanded: Bool = false

    enum DateExpansion {
        case none
        case startCalendar, startTime
        case dueCalendar, dueTime
        case recurrenceEnd
    }

    /// 인라인 캘린더/시각 wheel이 적용되는 날짜 필드.
    /// recurrenceEnd는 별도 경로 (recurrenceEndBinding) — 여기 포함 X.
    enum DateField { case start, due }

    @State private var showDeleteConfirm = false
    @State private var showCancelConfirm = false
    @State private var showRecurrenceSheet = false
    @State private var showPeriod: Bool
    @State private var recurrenceConfig: RecurrenceConfig?

    init(editing: Item? = nil, baseDate: Date? = nil) {
        self.editingItem = editing
        // 모든 startDate/dueDate state는 UTC anchor Date로 통일.
        // 새 항목의 default 또는 nil fallback도 todayCalendarAnchor 사용.
        if let item = editing {
            _title = State(initialValue: item.title ?? "")
            _notes = State(initialValue: item.notes ?? "")
            _kind = State(initialValue: item.itemKind)
            _hasStart = State(initialValue: item.startDate != nil)
            _startDate = State(initialValue: item.startDate ?? .todayCalendarAnchor)
            _hasDue = State(initialValue: item.dueDate != nil)
            _dueDate = State(initialValue: item.dueDate ?? Self.defaultDueDate(after: item.startDate))
            _priority = State(initialValue: item.itemPriority)
            _showPeriod = State(initialValue: Self.shouldUsePeriodMode(
                start: item.startDate, due: item.dueDate,
                startHour: item.startHourInt, dueHour: item.dueHourInt
            ))
            // 시각: non-optional. startHour 0~23, dueHour 0~24 (24=시간 미설정).
            // NTD에서 startHour==0(legacy nil)은 의미 모호 → default 정각으로 보정.
            let resolvedStartHour: Int = {
                if item.itemKind == .notTodo, item.startHour == nil {
                    return Item.defaultNextTopOfHour
                }
                return item.startHourInt
            }()
            _startHour = State(initialValue: resolvedStartHour)
            // NTD는 dueHour 미사용이라 startHour와 sync해 hasTime=true 유지 (시간 chip 노출 보장).
            // legacy NTD가 dueHour=24로 저장된 경우 hasTime=false로 잡혀 chip 숨겨지는 버그 방지.
            if item.itemKind == .notTodo {
                _dueHour = State(initialValue: resolvedStartHour)
            } else {
                _dueHour = State(initialValue: item.dueHourInt)
            }
            _recurrenceEndDate = State(initialValue: item.recurrenceEndDate)
            _ntdDurationHour = State(initialValue: item.ntdDurationHourInt)
            // 기존 Reminder 레코드에서 알림 offset 복원 (anchor별 1개 가정).
            let reminders = (item.reminders as? Set<Reminder>) ?? []
            let startReminder = reminders.first { ReminderAnchor(rawValue: $0.anchor) == .start }
            let dueReminder = reminders.first { ReminderAnchor(rawValue: $0.anchor) == .due }
            if item.itemKind == .notTodo {
                _ntdStartAlertOffset = State(initialValue: startReminder.map { Int($0.offsetMin) })
                _ntdEndAlertOffset = State(initialValue: dueReminder.map { Int($0.offsetMin) })
                _todoStartAlertOffset = State(initialValue: nil)
                _todoDueAlertOffset = State(initialValue: nil)
            } else {
                _ntdStartAlertOffset = State(initialValue: nil)
                _ntdEndAlertOffset = State(initialValue: nil)
                _todoStartAlertOffset = State(initialValue: startReminder.map { Int($0.offsetMin) })
                _todoDueAlertOffset = State(initialValue: dueReminder.map { Int($0.offsetMin) })
            }
            if let rule = item.recurrenceRule {
                _recurrenceConfig = State(initialValue: RecurrenceConfig(from: rule))
            } else {
                _recurrenceConfig = State(initialValue: nil)
            }
        } else {
            _title = State(initialValue: "")
            _notes = State(initialValue: "")
            _kind = State(initialValue: .todo)
            if let base = baseDate {
                // baseDate는 호출자(TodayView)가 UTC anchor로 넘김.
                _hasStart = State(initialValue: true)
                _startDate = State(initialValue: base)
                _hasDue = State(initialValue: true)
                _dueDate = State(initialValue: base)
            } else {
                _hasStart = State(initialValue: false)
                _startDate = State(initialValue: .todayCalendarAnchor)
                _hasDue = State(initialValue: false)
                _dueDate = State(initialValue: Self.defaultDueDate(after: nil))
            }
            _priority = State(initialValue: .none)
            _showPeriod = State(initialValue: false)
            // 새 항목 default — hasTime=false (종일 일정): dueHour=24 sentinel.
            // startHour는 사용자가 시간설정 toggle ON 시 wheel default로 사용.
            _startHour = State(initialValue: Item.defaultNextTopOfHour)
            _dueHour = State(initialValue: 24)
            _recurrenceEndDate = State(initialValue: nil)
            _ntdDurationHour = State(initialValue: nil)  // 미설정 = 한계까지
            // 새 항목 알림 default:
            //  - NTD: 시작/종료 모두 정시(0) ON
            //  - Todo: OFF (사용자 명시 ON)
            _ntdStartAlertOffset = State(initialValue: 0)
            _ntdEndAlertOffset = State(initialValue: 0)
            _todoStartAlertOffset = State(initialValue: nil)
            _todoDueAlertOffset = State(initialValue: nil)
            _recurrenceConfig = State(initialValue: nil)
        }
    }


    /// 기간 모드 판정 — `Item.isSingleSchedule`의 inverse.
    /// - 다른 날짜 → 기간
    /// - 같은 날짜 + dueHour==24 (시간 미설정) → 단일
    /// - 같은 날짜 + startHour==dueHour → 단일
    /// - 같은 날짜 + startHour!=dueHour → 기간
    private static func shouldUsePeriodMode(start: Date?, due: Date?, startHour: Int, dueHour: Int) -> Bool {
        guard let start, let due else { return false }
        if !Calendar.gmt.isDate(start, inSameDayAs: due) { return true }
        if dueHour == 24 { return false }  // 시간 미설정 종일 → 단일
        return startHour != dueHour
    }

    private var isEditing: Bool { editingItem != nil }
    private var isNTD: Bool { kind == .notTodo }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 반복 설정은 일정(시작일)이 있을 때만 의미 있음 — 미정(hasStart=false)이면 anchor가 없어 반복 정의 불가.
    /// NTD는 추가로 목표 시간이 있어야 의미 있음 (미설정 = 1회성).
    private var isRecurrenceSectionVisible: Bool {
        guard hasStart else { return false }
        if isNTD { return ntdDurationHour != nil }
        return true
    }

    /// 알림 offset 선택지 (분). 음수=사전, 0=정시. anchor instant 기준.
    /// 시각 있는 항목: 시각 기준 ±N분 (정시/10분 전/30분 전/1시간 전).
    private static let alertOffsetOptionsWithTime: [Int] = [0, -10, -30, -60]
    /// 시각 미설정(종일) Todo: anchor=startDate 0시 기준.
    /// - 당일 오전 9시  → +540분
    /// - 당일 오후 2시  → +840분
    /// - 당일 오후 7시  → +1140분
    /// - 1일전 오후 9시 → -180분 (= -24h + 21h)
    /// - 2일전 오후 9시 → -1620분 (= -48h + 21h)
    private static let alertOffsetOptionsNoTime: [Int] = [540, 840, 1140, -180, -1620]

    private var alertOffsetOptions: [Int] {
        // NTD는 항상 hasTime=true. Todo의 hasTime에 따라 옵션 세트 결정.
        hasTime ? Self.alertOffsetOptionsWithTime : Self.alertOffsetOptionsNoTime
    }

    /// 알림 section.
    /// - NTD: 시작 알림 + (목표 시간 있을 때) 목표 달성 알림 — 기본 모두 ON.
    /// - Todo: startDate/dueDate 중 하나라도 있으면 노출 — hasDue면 "마감 알림"(.due anchor),
    ///   hasStart만 있으면(단일 모드 반복 등) "시작 알림"(.start anchor).
    /// Picker selection은 Optional<Int> — nil이면 알림 OFF, 정수는 offset(분).
    @ViewBuilder
    private var alertSection: some View {
        if isNTD {
            Section("add.section.alert") {
                alertOffsetPicker(label: "alert.label.start", selection: $ntdStartAlertOffset)
                if ntdDurationHour != nil {
                    alertOffsetPicker(label: "alert.label.end", selection: $ntdEndAlertOffset)
                }
            }
        } else if hasStart || hasDue {
            Section("add.section.alert") {
                // 단일 모드: 시작 알림만 (단일은 시작=마감 같은 의미).
                // 기간 모드: 시작 알림 + 마감 알림 둘 다.
                alertOffsetPicker(label: "alert.label.start", selection: $todoStartAlertOffset)
                if showPeriod {
                    alertOffsetPicker(label: "alert.label.due", selection: $todoDueAlertOffset)
                }
            }
        }
    }

    /// 단일 알림 picker — menu style. "안 함" + offset 옵션 (hasTime에 따라 세트 다름).
    private func alertOffsetPicker(label: LocalizedStringKey, selection: Binding<Int?>) -> some View {
        Picker(selection: selection) {
            Text("alert.offset.disabled").tag(Optional<Int>.none)
            ForEach(alertOffsetOptions, id: \.self) { offset in
                Text(verbatim: alertOffsetLabel(offset)).tag(Optional(offset))
            }
        } label: {
            Text(label)
        }
        .pickerStyle(.menu)
    }

    private func alertOffsetLabel(_ offset: Int) -> String {
        // 시각 미설정 Todo 전용 offset 매핑 (절대 시각 표현).
        switch offset {
        case 540:   return String(localized: "alert.offset.same_day_9am")
        case 840:   return String(localized: "alert.offset.same_day_2pm")
        case 1140:  return String(localized: "alert.offset.same_day_7pm")
        case -180:  return String(localized: "alert.offset.day_before_9pm")
        case -1620: return String(localized: "alert.offset.two_days_before_9pm")
        default: break
        }
        // 시각 있는 항목 (NTD / Todo hasTime=true): ±N분 표기.
        if offset == 0 {
            return String(localized: "alert.offset.exact")
        }
        if offset == -60 {
            return String(localized: "alert.offset.hour_before")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("alert.offset.minutes_before_format", comment: ""),
            abs(offset)
        )
    }

    /// 활동 기록 section — RoutineCompletion 레코드 표시 (최신순 최대 10건).
    /// 통합 모델: 모든 체크는 RC 생성 → 1회성/반복 구분 없이 동일 소스.
    @ViewBuilder
    private var activityHistorySection: some View {
        if let item = editingItem {
            let records = item.routineHistoryRecords
            if !records.isEmpty {
                Section("activity.history.title") {
                    ForEach(records.prefix(10), id: \.objectID) { record in
                        activityRow(record)
                    }
                }
            }
        }
    }

    /// 활동 기록 row — 날짜 + (시간) + 상태 라벨 + 코멘트(있을 때, 포기엔 "사유: " prefix).
    /// 날짜·시간은 모두 RoutineCompletion.completedAt 기준 (= 사용자가 체크/포기한 실제 시점).
    /// RC.date는 occurrence 식별 용도라 표시에는 안 씀 — 미래 occurrence 미리 체크해도
    /// 표시는 체크한 그 시점으로 나타남.
    @ViewBuilder
    private func activityRow(_ record: RoutineCompletion) -> some View {
        let isDone = record.done
        // 표시 날짜는 completedAt 기준. 누락된 legacy record는 record.date로 fallback.
        let displayDay: Date? = record.completedAt?.calendarDateAnchor ?? record.date
        HStack(spacing: 8) {
            Text(verbatim: shortDate(displayDay))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let timeText = timeText(record.completedAt) {
                Text(verbatim: timeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if isDone {
                Text("activity.status.done")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("activity.status.failed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let comment = record.comment, !comment.isEmpty {
                Text(verbatim: commentText(comment: comment, isDone: isDone))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
    }

    /// RoutineCompletion.completedAt(instant)를 시스템 시간 표시 설정에 맞춰 포맷.
    /// 24h 모드: "14:30", 12h 모드: "오후 2:30" / "2:30 PM". UTC 변환 X (실제 시각).
    private func timeText(_ instant: Date?) -> String? {
        guard let instant else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter.string(from: instant)
    }

    /// 활동 기록 코멘트 표시 텍스트.
    /// 포기 기록은 "사유: ..." prefix, 성공 기록은 코멘트 그대로 (현재 done 코멘트는 거의 비어있음).
    private func commentText(comment: String, isDone: Bool) -> String {
        if isDone { return comment }
        return String.localizedStringWithFormat(
            NSLocalizedString("activity.reason_format", comment: ""),
            comment
        )
    }

    /// 포기 기록 row의 날짜 표시. UTC anchor 기준 "M.d (E)" 형식.
    private func shortDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        formatter.setLocalizedDateFormatFromTemplate("MdE")
        return formatter.string(from: date)
    }


    /// 입력 폼에 미저장 변경사항이 있는지.
    /// - 새 항목: 제목 또는 메모에 텍스트 입력 시 true.
    /// - 편집 항목: 현재 state가 editingItem 저장값과 다를 때 true.
    /// 사용처: 저장 버튼 색상(빨강), 취소 시 confirm 표시.
    private var hasChanges: Bool {
        guard let item = editingItem else {
            return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if (item.title ?? "") != title { return true }
        if (item.notes ?? "") != notes { return true }
        if item.itemKind != kind { return true }
        if (item.startDate != nil) != hasStart { return true }
        if hasStart, let s = item.startDate, s != startDate { return true }
        if (item.dueDate != nil) != hasDue { return true }
        if hasDue, let d = item.dueDate, d != dueDate { return true }
        if item.itemPriority != priority { return true }
        // 시각 — save 정규화 후 값과 비교 (hasTime/showPeriod 반영).
        let effectiveStartH: Int
        let effectiveDueH: Int
        if kind == .notTodo {
            effectiveStartH = startHour
            effectiveDueH = startHour  // NTD save와 동일 — startHour와 sync
        } else if !hasTime {
            effectiveStartH = 0
            effectiveDueH = 24
        } else {
            effectiveStartH = startHour
            effectiveDueH = showPeriod ? dueHour : startHour
        }
        if item.startHourInt != effectiveStartH { return true }
        if item.dueHourInt != effectiveDueH { return true }
        // 반복 종료일.
        if item.recurrenceEndDate != recurrenceEndDate { return true }
        // NTD 목표 시간.
        if kind == .notTodo {
            if item.ntdDurationHourInt != ntdDurationHour { return true }
        }
        // 반복 규칙 비교.
        let hadRule = (item.recurrenceRule != nil)
        let hasConfig = (recurrenceConfig != nil)
        if hadRule != hasConfig { return true }
        if let rule = item.recurrenceRule, let config = recurrenceConfig {
            if rule.itemFrequency != config.frequency { return true }
            if rule.interval != config.interval { return true }
            if rule.selectedWeekdays != config.weekdays { return true }
            if rule.selectedDays != config.days { return true }
            if rule.includesLastDay != config.includesLastDay { return true }
            if rule.selectedMonths != config.months { return true }
        }
        return false
    }

    /// 편집 시엔 "할일 수정" / "비움 수정"처럼 kind를 타이틀에 명시.
    /// (편집 모드에서 kind picker를 숨겼기 때문에 사용자가 종류를 파악할 단서로 사용.)
    private var navigationTitleText: String {
        if isEditing {
            return String.localizedStringWithFormat(
                NSLocalizedString("add.title.edit_format", comment: ""),
                kind.displayName
            )
        }
        return String(localized: "add.title.new")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("add.field.title", text: $title)
                        .focused($titleFocused)
                    TextField("add.field.notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                // 종류 picker. 편집 시엔 숨김 (Todo↔NTD 변환은 의미 shift 위험).
                if !isEditing {
                    Section {
                        Picker(selection: $kind) {
                            Text(ItemKind.todo.displayName).tag(ItemKind.todo)
                            Text(ItemKind.notTodo.displayName).tag(ItemKind.notTodo)
                        } label: {
                            Text("add.section.kind")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: kind) { _, newKind in
                            handleKindChange(newKind)
                        }
                    }
                }

                Section("add.section.schedule") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // NTD는 발생 calendar date 필수 + 단일 시작일만 의미 있음.
                            // → "미정" / "기간" chip은 NTD에선 숨김. NTD엔 시간설정도 항상 ON.
                            if !isNTD {
                                quickChip("add.chip.no_date", daysFromToday: nil)
                            }
                            quickChip("add.chip.today", daysFromToday: 0)
                            quickChip("add.chip.tomorrow", daysFromToday: 1)
                            if !isNTD {
                                periodChip
                                // 시간 설정 toggle은 다른 chip과 시각적 구분.
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(width: 1, height: 20)
                                    .padding(.horizontal, 2)
                                hasTimeChip
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                    // 시작 라인 — hasStart일 때 노출 (NTD는 anchor 필수라 항상 true).
                    // "시작" 라벨은 기간 모드일 때만 (단일 모드에선 종료가 같으니 라벨 불필요).
                    // 시간 chip은 hasTime ON일 때만 (NTD는 hasTime 강제 ON).
                    if hasStart {
                        HStack(spacing: 12) {
                            if showPeriod {
                                Text("add.label.start")
                                    .foregroundStyle(.primary)
                            }
                            Spacer()
                            dateSubchip(active: hasStart,
                                        expanded: dateExpansion == .startCalendar,
                                        date: startDate) {
                                toggleDateExpansion(.startCalendar)
                            }
                            if hasTime {
                                timeSubchip(hour: startHour,
                                            expanded: dateExpansion == .startTime) {
                                    toggleDateExpansion(.startTime)
                                }
                            }
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        if dateExpansion == .startCalendar {
                            inlineCalendarEditor(for: .start)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        } else if dateExpansion == .startTime && hasTime {
                            inlineTimeEditor(for: .start)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        }
                    }

                    // 마감 라인 — 기간 모드 + Todo (NTD는 별도 마감 시각 없음).
                    if showPeriod && !isNTD && hasDue {
                        HStack(spacing: 12) {
                            Text("add.label.end")
                                .foregroundStyle(.primary)
                            Spacer()
                            dateSubchip(active: hasDue,
                                        expanded: dateExpansion == .dueCalendar,
                                        date: dueDate) {
                                toggleDateExpansion(.dueCalendar)
                            }
                            if hasTime {
                                timeSubchip(hour: dueHour,
                                            expanded: dateExpansion == .dueTime) {
                                    toggleDateExpansion(.dueTime)
                                }
                            }
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        if dateExpansion == .dueCalendar {
                            inlineCalendarEditor(for: .due)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        } else if dateExpansion == .dueTime && hasTime {
                            inlineTimeEditor(for: .due)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        }
                    }

                    // NTD 목표 시간 — 일정 section의 별도 row(고정). 탭하면 인라인 wheel 확장.
                    // 펼침 시 dateExpansion(.startTime 등)은 함께 접어 동시 펼침 방지.
                    if isNTD {
                        Button {
                            withAnimation {
                                durationExpanded.toggle()
                                if durationExpanded { dateExpansion = .none }
                            }
                        } label: {
                            HStack {
                                Text("add.field.duration")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(verbatim: durationDisplayText)
                                    .foregroundStyle(durationExpanded ? Color.accentColor : Color.secondary)
                                Image(systemName: durationExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        if durationExpanded {
                            inlineDurationEditor
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        }
                    }
                }

                // Todo 전용: 우선순위.
                if !isNTD {
                    Section("add.section.priority") {
                        HStack(spacing: 12) {
                            ForEach(Priority.pickerOrder, id: \.self) { p in
                                priorityButton(p)
                            }
                            Spacer()
                        }
                    }
                }

                // 알림 section — NTD는 항상(시작/종료), Todo는 dueDate 있을 때만 마감 알림.
                alertSection

                // 반복 section: Todo는 항상, NTD는 목표 시간이 있을 때만.
                if isRecurrenceSectionVisible {
                    Section("add.section.recurrence") {
                        // 좌측 타이틀 + 우측 설정값 (다른 row와 일관된 layout).
                        Button {
                            showRecurrenceSheet = true
                        } label: {
                            HStack {
                                Text("add.field.recurrence")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(verbatim: recurrenceSummaryText)
                                    .foregroundStyle(recurrenceConfig == nil ? Color.secondary : Color.primary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        // 반복 종료일 row — 반복 section 보일 때 항상 노출.
                        // 반복 패턴 미설정 시 입력해도 의미는 없지만, 발견성을 위해 표시.
                        Button {
                            toggleDateExpansion(.recurrenceEnd)
                        } label: {
                            HStack {
                                Text("add.field.recurrence_end")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(verbatim: recurrenceEndDisplayText)
                                    .foregroundStyle(dateExpansion == .recurrenceEnd ? Color.accentColor : Color.secondary)
                                Image(systemName: dateExpansion == .recurrenceEnd ? "chevron.down" : "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if dateExpansion == .recurrenceEnd {
                            inlineRecurrenceEndEditor
                        }
                    }
                }

                if isEditing {
                    // 활동 기록 — 성공·포기 occurrence 일자별 표시 (Todo/NTD 공통).
                    activityHistorySection

                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("common.delete", systemImage: "trash")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .alert(
                            "add.delete_alert.title",
                            isPresented: $showDeleteConfirm
                        ) {
                            Button("common.cancel", role: .cancel) {}
                            Button("common.delete", role: .destructive) { deleteItem() }
                        } message: {
                            Text("add.delete_alert.message")
                        }
                    }
                }
            }
            // 키보드 dismiss: 스크롤 시작 즉시 닫힘.
            // 이전엔 .simultaneousGesture(TapGesture)로 빈 영역 탭 시 닫게 했지만
            // Form 하단 Button(삭제/종료) 탭과 충돌해 제거.
            .scrollDismissesKeyboard(.immediately)
            // sheet 열 때 title focus 해제. sheet 닫혀도 자동 복귀 안 되도록.
            // (FocusState는 sheet 표시 중에도 유지돼, 닫히면 키보드가 다시 올라오는 문제 해결.)
            .onChange(of: dateExpansion)       { _, expansion in if expansion != .none { titleFocused = false } }
            .onChange(of: durationExpanded)    { _, expanded in if expanded { titleFocused = false } }
            .onChange(of: showRecurrenceSheet) { _, n in if n { titleFocused = false } }
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") {
                        if hasChanges {
                            showCancelConfirm = true
                        } else {
                            dismiss()
                        }
                    }
                    .confirmationDialog(
                        "add.cancel_confirm.title",
                        isPresented: $showCancelConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("add.cancel_confirm.discard", role: .destructive) { dismiss() }
                        Button("common.cancel", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // 변경사항이 있을 때만 빨강 강조. 기본 상태는 시스템 toolbar 기본 색상(.primary).
                    Button {
                        save()
                    } label: {
                        Text("common.save")
                            .foregroundStyle(hasChanges ? Color.red : Color.primary)
                    }
                    .disabled(!canSave)
                }
            }
            .task {
                guard !isEditing else { return }
                try? await Task.sleep(for: .milliseconds(120))
                titleFocused = true
            }
            .sheet(isPresented: $showRecurrenceSheet) {
                // presetDate: 사용자가 설정한 시작일자 기준 요일/일자 pre-set. 없으면 오늘.
                RecurrenceSheet(
                    initialConfig: recurrenceConfig,
                    presetDate: hasStart ? startDate : .todayCalendarAnchor,
                    onSave: { config in
                        recurrenceConfig = config
                        ensureStartDateForRecurrence()
                    },
                    onClear: {
                        recurrenceConfig = nil
                    }
                )
            }
        }
        // 변경사항이 있으면 스와이프-다운으로 sheet 닫는 행위를 차단.
        // 닫을 때는 반드시 (x) 버튼을 통해서 → 확인 dialog 거치게 함 (실수 방지).
        // SwiftUI는 "드래그 시도 시 dialog 띄우기"를 직접 지원 안 함 → drag 자체를 막는 방식.
        .interactiveDismissDisabled(hasChanges)
    }

    /// kind 변경 시 state 일관성 유지.
    /// NTD로 전환: 시작일 강제 ON (anchor 필수), 단일 모드, startHour 보장.
    /// Todo로 전환: 별도 정리 없음 (NTD 잔재는 save에서 정리).
    private func handleKindChange(_ newKind: ItemKind) {
        // kind 변경 시 인라인 캘린더·duration 닫음.
        dateExpansion = .none
        durationExpanded = false
        guard newKind == .notTodo else { return }
        if !hasStart {
            hasStart = true
            startDate = .todayCalendarAnchor
        }
        showPeriod = false
        // NTD: startHour 필수, dueHour 미사용 (24 sentinel 유지 — hasTime은 derived).
        // NTD는 시간 chip이 항상 보여야 하므로 dueHour를 startHour로 sync해서 hasTime=true 보장.
        if startHour == 0 {
            startHour = Item.defaultNextTopOfHour
        }
        if dueHour == 24 {
            dueHour = startHour
        }
    }

    private func durationLabel(_ hours: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("ntd.duration_format", comment: ""),
            hours
        )
    }

    /// 목표 유지 시간 인라인 picker — 2 wheel.
    /// Day wheel: "미설정"(nil) + 0~30일. Hour wheel: 0~23 (항상 enable).
    /// 상호작용 규칙:
    /// - 총합 == 0 → state nil (미설정)
    /// - 총합 > 0 → state = days*24 + hours
    /// - 미설정 상태에서 hour spin → day=0으로 자동 변경 (총합 > 0이 되므로 nil 해제)
    /// - 0일+0시간 선택 → 자동 미설정 (총합 0)
    /// - 시간>0 + 일=미설정 선택 → 총합 0이 되어 hour wheel도 0으로 reset
    @ViewBuilder
    private var inlineDurationEditor: some View {
        HStack(spacing: 0) {
            Picker(selection: ntdDurationDaysBinding) {
                Text("ntd.duration.unset").tag(Optional<Int>.none)
                ForEach(0...30, id: \.self) { d in
                    Text(verbatim: ntdDayLabel(d)).tag(Optional(d))
                }
            } label: { EmptyView() }
                .pickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)

            Picker(selection: ntdDurationHoursBinding) {
                ForEach(0...23, id: \.self) { h in
                    Text(verbatim: ntdHourLabel(h)).tag(h)
                }
            } label: { EmptyView() }
                .pickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
    }

    /// 일 단위 wheel binding (Optional<Int>).
    /// - get: state nil → "미설정". 그 외 days = total/24.
    /// - set nil(미설정 선택) → state nil. set day=N → 총합 N*24+현재hour. 총합 0이면 nil로 normalize.
    private var ntdDurationDaysBinding: Binding<Int?> {
        Binding(
            get: {
                guard let total = ntdDurationHour else { return nil }
                return total / 24
            },
            set: { newDays in
                guard let d = newDays else {
                    ntdDurationHour = nil
                    return
                }
                let currentHours = (ntdDurationHour ?? 0) % 24
                let total = d * 24 + currentHours
                ntdDurationHour = total == 0 ? nil : total
            }
        )
    }

    /// 시 단위 wheel binding (non-optional Int, 0~23).
    /// - get: state nil이면 0. 그 외 hours = total%24.
    /// - set: 총합 = (현재day)*24 + newHours. 총합 0이면 nil로 normalize.
    ///   미설정 상태에서 hour spin해서 >0 되면 day 자동 0 (nil 해제).
    private var ntdDurationHoursBinding: Binding<Int> {
        Binding(
            get: { (ntdDurationHour ?? 0) % 24 },
            set: { newHours in
                let currentDays = (ntdDurationHour ?? 0) / 24
                let total = currentDays * 24 + newHours
                ntdDurationHour = total == 0 ? nil : total
            }
        )
    }

    private func ntdDayLabel(_ d: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("ntd.duration.day_format", comment: ""),
            d
        )
    }

    private func ntdHourLabel(_ h: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("ntd.duration_format", comment: ""),
            h
        )
    }

    private var startHourDisplayText: String {
        let h = startHour
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("j")  // 시스템 hour cycle 선호 따름
        var comps = DateComponents()
        comps.hour = h
        comps.minute = 0
        if let date = Calendar.current.date(from: comps) {
            return formatter.string(from: date)
        }
        // fallback (실패 시 단순 "n시" 형태)
        return String.localizedStringWithFormat(
            NSLocalizedString("ntd.start_hour_format", comment: ""),
            h
        )
    }

    /// Duration row 우측에 표시할 텍스트.
    /// nil이면 "미설정", 값이 있으면 "n일 m시간" / "n일" / "m시간" 중 적합한 표기.
    private var durationDisplayText: String {
        guard let total = ntdDurationHour else {
            return String(localized: "ntd.duration.unset")
        }
        let days = total / 24
        let hours = total % 24
        let dayPart = String.localizedStringWithFormat(
            NSLocalizedString("ntd.duration.day_format", comment: ""), days
        )
        let hourPart = String.localizedStringWithFormat(
            NSLocalizedString("ntd.duration_format", comment: ""), hours
        )
        if days == 0  { return hourPart }
        if hours == 0 { return dayPart }
        return "\(dayPart) \(hourPart)"
    }

    private func quickChip(_ titleKey: LocalizedStringKey, daysFromToday days: Int?) -> some View {
        let active = isQuickChipActive(daysFromToday: days)
        return Button {
            applyQuickDate(daysFromToday: days)
        } label: {
            Text(titleKey)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(active ? Color.accentColor : Color.clear)
                )
                .overlay(
                    Capsule().stroke(active ? Color.clear : Color.accentColor, lineWidth: 1)
                )
                .foregroundStyle(active ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func isQuickChipActive(daysFromToday days: Int?) -> Bool {
        guard let days else {
            return !showPeriod && !hasStart && !hasDue
        }
        guard !showPeriod, hasStart, hasDue else { return false }
        // 오늘 기준 UTC anchor에서 days만큼 더해 chip이 가리키는 calendar date 계산.
        guard let target = Calendar.gmt.date(byAdding: .day, value: days, to: .todayCalendarAnchor) else {
            return false
        }
        return Calendar.gmt.isDate(startDate, inSameDayAs: target)
            && Calendar.gmt.isDate(dueDate, inSameDayAs: target)
    }

    private func applyQuickDate(daysFromToday days: Int?) {
        // 미정 chip(days=nil): 날짜 제거 + 캘린더 닫음 (날짜가 없으니 캘린더 의미 X).
        // 오늘/내일 chip: 날짜만 변경, 캘린더 펼침/닫힘 상태 그대로 유지.
        // 시각은 state에 유지 — 사용자가 chip 토글해도 이전 시각 보존.
        guard let days else {
            dateExpansion = .none
            hasStart = false
            hasDue = false
            showPeriod = false
            return
        }
        guard let target = Calendar.gmt.date(byAdding: .day, value: days, to: .todayCalendarAnchor) else {
            return
        }
        hasStart = true
        startDate = target
        hasDue = true
        dueDate = target
        showPeriod = false
    }

    private func ensureStartDateForRecurrence() {
        guard recurrenceConfig != nil, !hasStart else { return }
        hasStart = true
        startDate = .todayCalendarAnchor
        if !showPeriod {
            dueDate = startDate
            hasDue = true
        }
    }

    private func formatMonthDay(_ day: Int) -> String {
        let lang = Locale.preferredLanguages.first ?? ""
        let valueStr: String
        if lang.hasPrefix("en") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .ordinal
            formatter.locale = Locale.current
            valueStr = formatter.string(from: NSNumber(value: day)) ?? "\(day)"
        } else {
            valueStr = "\(day)"
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("recurrence.day_format", comment: ""),
            valueStr
        )
    }

    private var recurrenceSummaryText: String {
        guard let config = recurrenceConfig else {
            return String(localized: "recurrence.empty")
        }
        switch config.frequency {
        case .daily:
            if config.interval <= 1 {
                return String(localized: "recurrence.summary.everyday")
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("recurrence.summary.every_n_days", comment: ""),
                config.interval
            )

        case .weekly:
            let weekdays = config.weekdays.sorted()
            if weekdays.isEmpty {
                return String(localized: "recurrence.summary.weekly_unset")
            }
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            let symbols = formatter.shortWeekdaySymbols ?? []
            let names = weekdays.compactMap { idx -> String? in
                guard idx >= 1, idx <= symbols.count else { return nil }
                return symbols[idx - 1]
            }
            let daysStr = names.joined(separator: " · ")
            return String.localizedStringWithFormat(
                NSLocalizedString("recurrence.summary.weekly_list", comment: ""),
                daysStr
            )

        case .monthly:
            let days = config.days.sorted()
            let hasLast = config.includesLastDay
            let totalCount = days.count + (hasLast ? 1 : 0)
            if totalCount == 0 {
                return String(localized: "recurrence.summary.monthly_unset")
            }

            let isList = totalCount <= 3
            let dayString: String
            if isList {
                var parts = days.map { formatMonthDay($0) }
                if hasLast {
                    parts.append(String(localized: "recurrence.last_day_short"))
                }
                dayString = parts.joined(separator: " · ")
            } else {
                dayString = ""
            }

            let months = config.months
            let isAllMonths = months.isEmpty || months.count >= 12

            if isAllMonths {
                if isList {
                    return String.localizedStringWithFormat(
                        NSLocalizedString("recurrence.summary.monthly_all", comment: ""),
                        dayString
                    )
                } else {
                    return String.localizedStringWithFormat(
                        NSLocalizedString("recurrence.summary.monthly_all_count", comment: ""),
                        totalCount
                    )
                }
            } else {
                let monthFormatter = DateFormatter()
                monthFormatter.locale = Locale.current
                let monthSymbols = monthFormatter.shortMonthSymbols ?? []
                let monthNames = months.sorted().compactMap { idx -> String? in
                    guard idx >= 1, idx <= monthSymbols.count else { return nil }
                    return monthSymbols[idx - 1]
                }
                let monthStr = monthNames.joined(separator: " · ")
                if isList {
                    return String.localizedStringWithFormat(
                        NSLocalizedString("recurrence.summary.monthly_specific", comment: ""),
                        dayString,
                        monthStr
                    )
                } else {
                    return String.localizedStringWithFormat(
                        NSLocalizedString("recurrence.summary.monthly_specific_count", comment: ""),
                        totalCount,
                        monthStr
                    )
                }
            }

        default:
            return String(localized: "recurrence.empty")
        }
    }

    private func priorityButton(_ p: Priority) -> some View {
        let selected = priority == p
        return Button {
            priority = p
        } label: {
            Image(systemName: p == .none ? "flag.slash" : "flag.fill")
                .font(.title3)
                .foregroundStyle(Self.flagColor(for: p))
                .frame(width: 40, height: 40)
                .background(
                    Circle().fill(selected ? Color(.secondarySystemFill) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    static func flagColor(for priority: Priority) -> Color {
        switch priority {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .blue
        case .none:   return .secondary
        }
    }

    private var periodChip: some View {
        Button {
            // exclusive 동작 — 이미 활성이면 no-op (오늘/내일/미정 chip으로만 해제).
            guard !showPeriod else { return }
            showPeriod = true
            if !hasStart {
                hasStart = true
                startDate = .todayCalendarAnchor
            }
            // 기간 모드는 다른 두 일자 의미 — start+1로 default 채움 (이미 hasDue=true여도 덮어쓰기).
            hasDue = true
            dueDate = Self.defaultDueDate(after: startDate)
            // dateExpansion 유지 — chip 클릭은 캘린더 토글하지 않음.
        } label: {
            Text("add.chip.period")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(showPeriod ? Color.accentColor : Color.clear)
                )
                .overlay(
                    Capsule().stroke(showPeriod ? Color.clear : Color.accentColor, lineWidth: 1)
                )
                .foregroundStyle(showPeriod ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    /// "시간설정" 독립 toggle chip — `dueHour < 24` 여부로 derived state.
    /// OFF 전환 → `dueHour = 24` (sentinel). ON 전환 → `dueHour = startHour` (단일 모드 default).
    /// ON 후 사용자가 wheel로 dueHour 변경하면 그 값 유지.
    private var hasTimeChip: some View {
        Button {
            withAnimation {
                if hasTime {
                    // 현재 ON → OFF로 전환. dueHour를 sentinel 24로.
                    dueHour = 24
                    if dateExpansion == .startTime || dateExpansion == .dueTime {
                        dateExpansion = .none
                    }
                } else {
                    // 현재 OFF → ON으로 전환. dueHour를 startHour로 sync (사용자가 wheel로 재설정 가능).
                    dueHour = startHour
                }
                // hasTime 전환 시 알림 offset reset — 옵션 세트가 달라져 값 호환 X.
                todoStartAlertOffset = nil
                todoDueAlertOffset = nil
            }
        } label: {
            Text("add.chip.has_time")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(hasTime ? Color.accentColor : Color.clear)
                )
                .overlay(
                    Capsule().stroke(hasTime ? Color.clear : Color.accentColor, lineWidth: 1)
                )
                .foregroundStyle(hasTime ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    /// 인라인 캘린더 영역 toggle. 같은 chip 다시 누르면 닫힘.
    /// 다른 영역(목표 시간 wheel 등) 펼쳐져 있으면 함께 접음 — 동시 펼침 방지.
    private func toggleDateExpansion(_ target: DateExpansion) {
        withAnimation {
            dateExpansion = (dateExpansion == target) ? .none : target
            if dateExpansion != .none { durationExpanded = false }
        }
    }

    /// 인라인 캘린더 — DatePicker만. "날짜 없음" 버튼은 chip 'no_date'(미정)와 중복이라 제거.
    /// 시각 입력은 별도 timeSubchip → inlineTimeEditor로 분리됨.
    /// 마감(.due)은 시작일자 이전 선택 못하게 DatePicker range 제한.
    @ViewBuilder
    private func inlineCalendarEditor(for field: DateField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if field == .due && showPeriod {
                DatePicker(
                    "",
                    selection: dateBinding(for: field),
                    in: startDate.localCalendarSameDay...,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .environment(\.locale, Locale.current)
            } else {
                DatePicker(
                    "",
                    selection: dateBinding(for: field),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .environment(\.locale, Locale.current)
            }
        }
        .padding(.vertical, 4)
    }

    /// 인라인 시각 wheel — 시 단위.
    /// wheel은 0~23 단일 옵션. "시간 미설정"은 chip toggle로만 (wheel에서 분리).
    /// 마감(.due) 시각은 같은 날짜일 때 시작 시각 이후만 노출 (validation).
    @ViewBuilder
    private func inlineTimeEditor(for field: DateField) -> some View {
        HStack {
            Spacer()
            Picker(selection: hourBinding(for: field)) {
                ForEach(validHours(for: field), id: \.self) { h in
                    Text(verbatim: todoHourLabel(h)).tag(h)
                }
            } label: { EmptyView() }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: 240)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// 시각 wheel에 노출할 유효 시간 목록.
    /// - 시작(.start): 0~23 항상 자유 (마감 invalidate는 setter 측에서 정리).
    /// - 마감(.due): 같은 날짜·기간 모드면 시작+1 이후만. 다른 날짜면 0~23.
    /// 단, 현재 dueHour가 filter 밖(legacy 데이터)이라도 wheel에 포함 — wheel selection 매칭 보장.
    private func validHours(for field: DateField) -> [Int] {
        guard field == .due, showPeriod,
              Calendar.gmt.isDate(startDate, inSameDayAs: dueDate)
        else { return Array(0..<24) }
        var hours = Array((startHour + 1)..<24)
        if !hours.contains(dueHour) && dueHour < 24 {
            hours.append(dueHour)
            hours.sort()
        }
        return hours
    }

    /// 반복 종료일 row 우측 표시. 미설정이면 "무기한".
    private var recurrenceEndDisplayText: String {
        guard let date = recurrenceEndDate else {
            return String(localized: "recurrence_end.unset")
        }
        return formattedDateShort(date)
    }

    /// 반복 종료일 인라인 캘린더 + "무기한" 버튼.
    @ViewBuilder
    private var inlineRecurrenceEndEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker(
                "",
                selection: recurrenceEndBinding,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .environment(\.locale, Locale.current)

            HStack {
                Spacer()
                if recurrenceEndDate != nil {
                    Button(role: .destructive) {
                        recurrenceEndDate = nil
                        withAnimation { dateExpansion = .none }
                    } label: {
                        Text("recurrence_end.unset")
                            .font(.subheadline)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// 반복 종료일 binding — UTC anchor ↔ local. nil이면 오늘로 시작.
    private var recurrenceEndBinding: Binding<Date> {
        Binding(
            get: { (recurrenceEndDate ?? .todayCalendarAnchor).localCalendarSameDay },
            set: { recurrenceEndDate = $0.calendarDateAnchor }
        )
    }

    /// Todo 시각 라벨 (시스템 12h/24h 자동).
    private func todoHourLabel(_ h: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("j")
        var comps = DateComponents()
        comps.hour = h
        comps.minute = 0
        if let date = Calendar.current.date(from: comps) {
            return formatter.string(from: date)
        }
        return "\(h)"
    }

    private func hourBinding(for field: DateField) -> Binding<Int> {
        Binding(
            get: {
                switch field {
                case .start: return startHour
                case .due:   return dueHour
                }
            },
            set: { newValue in
                switch field {
                case .start:
                    startHour = newValue
                    // 단일 모드: dueHour를 startHour와 sync (한 시간만 의미).
                    if !showPeriod { dueHour = newValue }
                    // 기간 모드 + 같은 날 + due가 새 start 이하면 due를 start+1로 보정.
                    if showPeriod, hasDue,
                       Calendar.gmt.isDate(startDate, inSameDayAs: dueDate),
                       dueHour <= newValue {
                        dueHour = min(newValue + 1, 23)
                    }
                case .due:
                    dueHour = newValue
                }
            }
        )
    }

    /// UTC anchor ↔ local Date 변환 binding.
    /// - get: state(UTC anchor) → local 같은 (y,m,d) 자정 instant (DatePicker 표시용)
    /// - set: DatePicker 결과(local 자정) → UTC anchor로 정규화해 state 저장 + hasStart/hasDue 자동 ON
    /// 단일 chip 모드에선 start 변경 시 due도 같이 따라옴.
    /// 기간 모드 + start 변경 시 due가 start 이전이면 due를 start로 sync (validation).
    private func dateBinding(for field: DateField) -> Binding<Date> {
        Binding(
            get: {
                switch field {
                case .start: return startDate.localCalendarSameDay
                case .due:   return dueDate.localCalendarSameDay
                }
            },
            set: { newValue in
                let anchor = newValue.calendarDateAnchor
                switch field {
                case .start:
                    startDate = anchor
                    hasStart = true
                    if !showPeriod {
                        dueDate = anchor
                        hasDue = true
                    } else if hasDue, dueDate < anchor {
                        // 기간 모드: 새 start가 due보다 미래 → due를 sync.
                        // dueHour가 startHour 이하로 invalid면 start+1로 보정 (sentinel 24면 그대로).
                        dueDate = anchor
                        if dueHour < 24, dueHour <= startHour {
                            dueHour = min(startHour + 1, 23)
                        }
                    } else if hasDue,
                              Calendar.gmt.isDate(anchor, inSameDayAs: dueDate),
                              dueHour < 24, dueHour <= startHour {
                        dueHour = min(startHour + 1, 23)
                    }
                case .due:
                    dueDate = anchor
                    hasDue = true
                }
            }
        )
    }

    /// 날짜 subchip — 📅 + 날짜 텍스트(active) 또는 "날짜 없음"(inactive).
    /// 캡슐 배경으로 chip 형태 강조. expanded면 accent tint 배경.
    private func dateSubchip(active: Bool, expanded: Bool, date: Date, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .foregroundStyle(
                        expanded ? Color.accentColor
                                 : (active ? Color.primary : Color.secondary)
                    )
                if active {
                    Text(verbatim: formattedDateShort(date))
                } else {
                    Text("common.no_date")
                }
            }
            .font(.subheadline)
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    expanded ? Color.accentColor.opacity(0.15) : Color(.secondarySystemFill)
                )
            )
        }
        .buttonStyle(.plain)
    }

    /// 시각 subchip — ⏰ + 시각 텍스트. hasTime ON일 때만 렌더되므로 hour는 항상 0~23.
    /// 캡슐 배경으로 chip 형태 강조.
    private func timeSubchip(hour: Int, expanded: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .foregroundStyle(expanded ? Color.accentColor : Color.primary)
                Text(verbatim: todoHourLabel(hour))
            }
            .font(.subheadline)
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    expanded ? Color.accentColor.opacity(0.15) : Color(.secondarySystemFill)
                )
            )
        }
        .buttonStyle(.plain)
    }

    private func formattedDateShort(_ date: Date) -> String {
        // date는 UTC anchor. timezone=.gmt로 고정한 formatter로 해석해야
        // local timezone에 따라 라벨이 흔들리지 않음.
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let dateYear = Calendar.gmt.component(.year, from: date)
        let currentYear = Calendar.gmt.component(.year, from: .todayCalendarAnchor)
        formatter.setLocalizedDateFormatFromTemplate(dateYear == currentYear ? "MdE" : "yMdE")
        return formatter.string(from: date)
    }

    private static func defaultDueDate(after base: Date?) -> Date {
        // base가 nil이면 오늘, 있으면 그 다음 날을 default due로.
        // 모두 UTC anchor 기준.
        let anchor = base.map { Calendar.gmt.startOfDay(for: $0) } ?? .todayCalendarAnchor
        return Calendar.gmt.date(byAdding: .day, value: 1, to: anchor) ?? anchor
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNew = editingItem == nil
        let item: Item
        if let existing = editingItem {
            item = existing
        } else {
            // make은 default priority로 시작 — 아래에서 kind에 따라 다시 정리.
            item = Item.make(in: context, kind: kind, title: trimmed, priority: priority)
        }
        // 활성화 트리거 판단용 snapshot — 1회성 NTD가 failed/done 상태에서
        // 시각 정보 변경 시 자동 재활성화하기 위함.
        let wasRecurring = (editingItem?.recurrenceRule != nil)
        let priorStatus = editingItem?.itemStatus
        let priorStartDate = editingItem?.startDate
        let priorStartHour = editingItem?.startHourInt
        let priorDurationHour = editingItem?.ntdDurationHourInt
        item.title = trimmed
        item.notes = notes.isEmpty ? nil : notes
        item.itemKind = kind
        item.startDate = hasStart ? startDate : nil
        item.dueDate = hasDue ? dueDate : nil
        item.isSomeday = !hasStart && !hasDue
        item.recurrenceEndDate = recurrenceEndDate
        item.updatedAt = Date()

        if isNTD {
            // NTD: startHour 필수 anchor. dueHour는 NTD에서 미사용이지만,
            // hasTime(dueHour<24) 판정이 NTD에서도 true가 되도록 startHour와 sync.
            // (24로 저장하면 재진입 시 hasTime=false → 시간 chip 숨겨지는 버그)
            item.startHourInt = startHour
            item.dueHourInt = startHour
            item.ntdDurationHourInt = ntdDurationHour
            item.itemPriority = .none
            item.itemStartTimeOfDay = .none
            item.itemDueTimeOfDay = .none
            item.ntdStartHour = nil  // legacy
            if item.startDate == nil {
                item.startDate = .todayCalendarAnchor
                item.isSomeday = false
            }
        } else {
            // Todo: 시각 0~23(start), 0~24(due). 24=시간 미설정 sentinel.
            // hasTime=false → 종일 일정: startHour=0, dueHour=24.
            // hasTime=true + 단일 모드: dueHour=startHour로 sync.
            // hasTime=true + 기간 모드: 둘 다 그대로.
            item.itemPriority = priority
            if !hasTime {
                item.startHourInt = 0
                item.dueHourInt = 24
            } else {
                item.startHourInt = startHour
                item.dueHourInt = showPeriod ? dueHour : startHour
            }
            item.itemStartTimeOfDay = .none
            item.itemDueTimeOfDay = .none
            item.ntdStartHour = nil
            item.ntdDurationHourInt = nil
        }

        // 반복 설정 적용.
        // NTD에서 ntdDurationHour=nil이면 반복 의미 없음 → recurrenceConfig 무시하고 제거.
        let effectiveRecurrence: RecurrenceConfig? = (isNTD && ntdDurationHour == nil) ? nil : recurrenceConfig

        if let config = effectiveRecurrence {
            // 1회성 → 반복 전환 시 종료된 status(done/failed) 재활성화.
            // 기존 RoutineCompletion 기록은 보존됨 (체크 시점에 RC가 이미 생성되어 있음 → 통합 모델).
            if !wasRecurring && (item.itemStatus == .done || item.itemStatus == .failed) {
                item.itemStatus = .pending
                item.completedAt = nil
            }
            if item.startDate == nil {
                // 루틴은 anchor가 필수 → 오늘(UTC anchor)을 startDate로.
                item.startDate = .todayCalendarAnchor
                item.isSomeday = false
            }
            // 단일 chip 모드: dueDate는 Todo 마감일이라 routine에선 안 쓰임 → nil로.
            // (routine 종료일은 별도 recurrenceEndDate 필드에 저장)
            if !showPeriod {
                item.dueDate = nil
            }
            let rule = item.recurrenceRule ?? RecurrenceRule.make(in: context)
            config.apply(to: rule)
            item.recurrenceRule = rule
        } else if let existing = item.recurrenceRule {
            context.delete(existing)
            item.recurrenceRule = nil
        }

        // 1회성 NTD failed/done 상태에서 시각 정보가 변경됐으면 자동 재활성화.
        // 사용자가 시간/날짜/duration을 바꾼 것은 "다시 시도" 의도로 해석.
        // 기존 RoutineCompletion 기록은 보존됨 (활동 로그·사유 history 유지).
        if isNTD,
           !wasRecurring,
           item.recurrenceRule == nil,
           let prior = priorStatus,
           prior == .done || prior == .failed {
            let startDateChanged = priorStartDate != item.startDate
            let startHourChanged = priorStartHour != startHour
            let durationChanged = priorDurationHour != ntdDurationHour
            if startDateChanged || startHourChanged || durationChanged {
                item.itemStatus = .pending
                item.completedAt = nil
            }
        }

        // 알림 Reminder 레코드 reconcile — UI state(offset Optional<Int>) → DB.
        reconcileReminders(item: item)

        ItemEvent.log(isNew ? .created : .updated, on: item, in: context)

        do {
            try context.save()
            Item.completeExpiredRoutines(in: context)
            Item.completeFinishedNTDs(in: context)
            // OS 알림 등록/갱신은 DB 저장 후. Reminder.id가 안정적이어야 OS notification id와 매칭됨.
            item.syncNotifications()
            dismiss()
        } catch {
            assertionFailure("Save failed: \(error)")
        }
    }

    /// AddItemView state의 알림 toggle/offset → Reminder 레코드 동기화.
    /// anchor별 1개 reminder 정책 (V1). 이미 있으면 offset 업데이트, 없으면 생성, 토글 OFF면 삭제.
    private func reconcileReminders(item: Item) {
        let existing = (item.reminders as? Set<Reminder>) ?? []
        // 같은 anchor에 중복 reminder가 들어와 있으면 (CloudKit 충돌 등으로 발생 가능) 1개만 유지하고 나머지는 정리.
        // 정리 안 하면 syncNotifications가 reminder마다 OS 알림을 등록해 동일 내용이 중복 fire.
        var anchorBuckets: [Int16: [Reminder]] = [:]
        for r in existing { anchorBuckets[r.anchor, default: []].append(r) }
        var byAnchor: [Int16: Reminder] = [:]
        for (anchor, group) in anchorBuckets {
            let sorted = group.sorted {
                ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
            }
            byAnchor[anchor] = sorted.first
            for dup in sorted.dropFirst() {
                if let rid = dup.id {
                    Item.cancelNotifications(forReminderID: rid)
                }
                context.delete(dup)
            }
        }

        // (anchor, offset) target 목록 — UI state 기반.
        var targets: [(Int16, Int)] = []
        if isNTD {
            if let o = ntdStartAlertOffset {
                targets.append((ReminderAnchor.start.rawValue, o))
            }
            if ntdDurationHour != nil, let o = ntdEndAlertOffset {
                targets.append((ReminderAnchor.due.rawValue, o))
            }
        } else if hasStart || hasDue {
            // 단일: 시작 알림만. 기간: 시작 + 마감 둘 다.
            if let o = todoStartAlertOffset {
                targets.append((ReminderAnchor.start.rawValue, o))
            }
            if showPeriod, let o = todoDueAlertOffset {
                targets.append((ReminderAnchor.due.rawValue, o))
            }
        }
        let targetAnchors = Set(targets.map { $0.0 })

        // target에 없는 anchor reminder는 삭제.
        // CD에서 제거하기 전, 해당 Reminder.id로 발급된 모든 occurrence OS 알림(prefix 매칭) 취소 →
        // syncNotifications가 reminderSet 순회 시 이미 사라진 Reminder는 못 봐서 orphan이 남는 문제 방지.
        for (anchor, reminder) in byAnchor where !targetAnchors.contains(anchor) {
            if let rid = reminder.id {
                Item.cancelNotifications(forReminderID: rid)
            }
            context.delete(reminder)
        }
        // upsert.
        for (anchor, offset) in targets {
            if let r = byAnchor[anchor] {
                r.offsetMin = Int32(offset)
            } else {
                let r = Reminder(context: context)
                r.id = UUID()
                r.anchor = anchor
                r.offsetMin = Int32(offset)
                r.item = item
            }
        }
    }

    private func deleteItem() {
        guard let item = editingItem else { return }
        // 삭제 전 OS 알림 취소 (Item이 사라지면 Reminder.id 접근 불가).
        item.cancelAllNotifications()
        ItemEvent.log(.deleted, on: item, in: context)
        context.delete(item)
        do {
            try context.save()
            dismiss()
        } catch {
            assertionFailure("Delete failed: \(error)")
        }
    }

}

#Preview("New") {
    AddItemView()
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
