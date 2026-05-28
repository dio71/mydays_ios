import SwiftUI

struct RecurrenceSheet: View {

    let initialConfig: RecurrenceConfig?
    let presetDate: Date  // 신규 config 생성 시 요일/일자 preset 기준 (UTC anchor)
    let onSave: (RecurrenceConfig) -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var config: RecurrenceConfig
    /// 매월 sub-tab — 일자지정 / 조건지정 mutually exclusive.
    @State private var monthlyTab: MonthlyTab = .day

    enum MonthlyTab: Hashable { case day, condition }

    init(
        initialConfig: RecurrenceConfig?,
        presetDate: Date = .todayCalendarAnchor,
        onSave: @escaping (RecurrenceConfig) -> Void,
        onClear: @escaping () -> Void
    ) {
        self.initialConfig = initialConfig
        self.presetDate = presetDate
        self.onSave = onSave
        self.onClear = onClear
        // 신규 config: 요일·일자를 presetDate 기준으로 preset.
        // 기존 config 편집은 사용자 선택값 보존.
        let initial = initialConfig ?? Self.makeDefault(presetDate: presetDate)
        self._config = State(initialValue: initial)
        // 매월 default tab — weekdayOrdinal 있거나 legacy 말일+일자없음이면 조건지정으로 시작.
        let defaultTab: MonthlyTab = {
            if initial.weekdayOrdinal != nil { return .condition }
            if initial.includesLastDay && initial.days.isEmpty { return .condition }
            return .day
        }()
        self._monthlyTab = State(initialValue: defaultTab)
    }

    /// presetDate 기준 default config — 매주는 그날의 요일, 매월은 그날의 일자(또는 말일) pre-set.
    private static func makeDefault(presetDate: Date) -> RecurrenceConfig {
        var config = RecurrenceConfig.makeDefault()
        let weekday = Calendar.gmt.component(.weekday, from: presetDate)
        let day = Calendar.gmt.component(.day, from: presetDate)
        let isLastDay: Bool = {
            guard let range = Calendar.gmt.range(of: .day, in: .month, for: presetDate) else { return false }
            return day == range.last
        }()
        config.weekdays = [weekday]
        if isLastDay {
            config.includesLastDay = true
        } else {
            config.days = [day]
        }
        return config
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("recurrence.frequency.label", selection: $config.frequency) {
                        Text("recurrence.frequency.daily").tag(Frequency.daily)
                        Text("recurrence.frequency.weekly").tag(Frequency.weekly)
                        Text("recurrence.frequency.monthly").tag(Frequency.monthly)
                        Text("recurrence.frequency.yearly").tag(Frequency.yearly)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: config.frequency) { _, newFreq in
                        // 매년으로 전환 시 month 비어있으면 presetDate 월로 preset, day 비어있으면 presetDate 일로 preset.
                        // 매월로 돌아갈 때 monthMask는 모든 월(=Set(1...12))로 reset.
                        switch newFreq {
                        case .yearly:
                            if config.months.isEmpty || config.months.count == 12 {
                                let m = Calendar.gmt.component(.month, from: presetDate)
                                config.months = [m]
                            }
                            if config.days.isEmpty && !config.includesLastDay {
                                let d = Calendar.gmt.component(.day, from: presetDate)
                                config.days = [d]
                            }
                        case .monthly:
                            config.months = Set(1...12)
                        default: break
                        }
                    }
                }

                switch config.frequency {
                case .daily:
                    dailySection
                case .weekly:
                    weeklySection
                case .monthly:
                    monthlySection
                case .yearly:
                    yearlySection
                default:
                    EmptyView()
                }

                if initialConfig != nil {
                    Section {
                        Button(role: .destructive) {
                            onClear()
                            dismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Text("recurrence.remove")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("recurrence.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        onSave(config)
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - daily

    private var dailySection: some View {
        Section {
            intervalStepper(unitKey: "recurrence.interval.unit.day", range: 1...365)
        }
    }

    // MARK: - weekly

    private var weeklySection: some View {
        Group {
            Section {
                intervalStepper(unitKey: "recurrence.interval.unit.week", range: 1...52)
            }
            Section("recurrence.weekdays") {
                HStack(spacing: 4) {
                    ForEach(weekdayOrder, id: \.self) { w in
                        weekdayButton(w)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// 공통 interval Stepper — 단위 키만 frequency별로 다름 ("일/주/개월/년").
    private func intervalStepper(unitKey: LocalizedStringKey, range: ClosedRange<Int>) -> some View {
        Stepper(value: $config.interval, in: range) {
            HStack {
                Text("recurrence.interval.label")
                Spacer()
                Text(verbatim: "\(config.interval)")
                    .foregroundStyle(.secondary)
                Text(unitKey)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var weekdayOrder: [Int] {
        let first = Calendar.current.firstWeekday  // 1=Sun
        return (0..<7).map { ((first - 1 + $0) % 7) + 1 }
    }

    private func weekdayButton(_ weekday: Int) -> some View {
        let selected = config.weekdays.contains(weekday)
        return Button {
            if selected { config.weekdays.remove(weekday) }
            else        { config.weekdays.insert(weekday) }
        } label: {
            Text(verbatim: shortWeekdaySymbol(weekday))
                .font(.subheadline.weight(.medium))
                .frame(width: 36, height: 36)
                .background(Circle().fill(selected ? Color.accentColor : Color(.systemGray5)))
                .overlay { if !selected { Circle().stroke(Color(.systemGray3), lineWidth: 0.5) } }
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func shortWeekdaySymbol(_ weekday: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        return formatter.veryShortWeekdaySymbols[weekday - 1]
    }

    // MARK: - monthly

    /// 매월 — interval + 일자지정/조건지정 sub-tab (mutually exclusive).
    /// 일자지정: 1~31 grid. 조건지정: 말일 toggle (추후 첫째주 월요일 등 추가 예정).
    private var monthlySection: some View {
        Group {
            Section {
                intervalStepper(unitKey: "recurrence.interval.unit.month", range: 1...60)
                Picker("recurrence.monthly.mode", selection: $monthlyTab) {
                    Text("recurrence.monthly.mode.day").tag(MonthlyTab.day)
                    Text("recurrence.monthly.mode.condition").tag(MonthlyTab.condition)
                }
                .pickerStyle(.segmented)
                .onChange(of: monthlyTab) { _, new in
                    // Mutually exclusive — 다른 탭의 데이터는 clear.
                    switch new {
                    case .day:
                        config.includesLastDay = false
                        config.weekdayOrdinal = nil
                        config.weekdays = []
                    case .condition:
                        config.days = []
                        config.includesLastDay = false
                        // 조건지정 진입 시 ordinal 없으면 "첫번째 + 날" preset.
                        if config.weekdayOrdinal == nil {
                            config.weekdayOrdinal = 1
                            config.weekdays = []
                        }
                    }
                }
            }
            switch monthlyTab {
            case .day:
                Section("recurrence.days") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                        ForEach(1...31, id: \.self) { d in
                            dayButton(d)
                        }
                    }
                }
            case .condition:
                conditionSection
            }
        }
    }

    // MARK: - condition tab (N번째 weekday / N번째 날)

    /// 조건지정: 2행 chip — ordinal × target (weekday 또는 "날") 조합.
    /// 둘 다 exclusive 선택. 둘 다 선택돼야 의미 있음.
    private var conditionSection: some View {
        Group {
            Section("recurrence.condition.ordinal") {
                FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(ordinalOrder, id: \.self) { o in
                        ordinalChip(o)
                    }
                }
            }
            Section("recurrence.condition.target") {
                FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(targetOrder, id: \.self) { t in
                        targetChip(t)
                    }
                }
            }
        }
    }

    /// ordinal 표시 순서 — 1~5 + last sentinel(-1).
    private var ordinalOrder: [Int] { [1, 2, 3, 4, 5, RecurrenceRule.lastOrdinalSentinel] }

    /// target 표시 순서 — 요일 7개(firstWeekday 기준) + "날"(0 sentinel).
    private var targetOrder: [Int] {
        let first = Calendar.current.firstWeekday
        let weekdays = (0..<7).map { ((first - 1 + $0) % 7) + 1 }
        return weekdays + [0]  // 0 = "날"
    }

    /// ordinal chip — 첫번째~다섯번째 / 마지막.
    /// 선택 시 config.weekdayOrdinal 설정. 단일 선택 (다른 ordinal로 바뀜).
    private func ordinalChip(_ ordinal: Int) -> some View {
        let selected = config.weekdayOrdinal == ordinal
        return Button {
            config.weekdayOrdinal = ordinal
        } label: {
            Text(Self.ordinalLabel(ordinal))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Capsule().fill(selected ? Color.accentColor : Color(.systemGray5)))
                .overlay { if !selected { Capsule().stroke(Color(.systemGray3), lineWidth: 0.5) } }
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    /// target chip — 요일 1~7 또는 "날"(0).
    /// 선택 시 weekdayMask 단일 비트(요일) 또는 0("날"). 일자지정과 mutually exclusive 위해 days/includesLastDay clear.
    private func targetChip(_ target: Int) -> some View {
        let selected = isTargetSelected(target)
        return Button {
            applyTarget(target)
        } label: {
            Text(verbatim: Self.targetLabel(target))
                .font(.subheadline.weight(.medium))
                .frame(width: 36, height: 36)
                .background(Circle().fill(selected ? Color.accentColor : Color(.systemGray5)))
                .overlay { if !selected { Circle().stroke(Color(.systemGray3), lineWidth: 0.5) } }
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func isTargetSelected(_ target: Int) -> Bool {
        if target == 0 {
            // "날" — weekdayMask 비어있고 ordinal이 설정돼야 함.
            return config.weekdays.isEmpty
        }
        return config.weekdays == [target]
    }

    private func applyTarget(_ target: Int) {
        if target == 0 {
            config.weekdays = []
        } else {
            config.weekdays = [target]
        }
    }

    private static func ordinalLabel(_ ordinal: Int) -> LocalizedStringKey {
        switch ordinal {
        case 1: return "recurrence.condition.ordinal.first"
        case 2: return "recurrence.condition.ordinal.second"
        case 3: return "recurrence.condition.ordinal.third"
        case 4: return "recurrence.condition.ordinal.fourth"
        case 5: return "recurrence.condition.ordinal.fifth"
        case RecurrenceRule.lastOrdinalSentinel: return "recurrence.condition.ordinal.last"
        default: return ""
        }
    }

    private static func targetLabel(_ target: Int) -> String {
        if target == 0 { return String(localized: "recurrence.condition.target.day") }
        let f = DateFormatter()
        f.locale = Locale.current
        return f.veryShortWeekdaySymbols[target - 1]
    }

    // MARK: - yearly

    /// 매년 — interval + 월 선택. 일자는 startDate.day 기반 자동 (필요 시 매월 탭에서 변경).
    /// `Picker.onChange` 핸들러가 .yearly 전환 시 month/day preset 처리.
    private var yearlySection: some View {
        Group {
            Section {
                intervalStepper(unitKey: "recurrence.interval.unit.year", range: 1...50)
            }
            Section("recurrence.months") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(1...12, id: \.self) { m in
                        monthButton(m)
                    }
                }
            }
        }
    }

    private func dayButton(_ day: Int) -> some View {
        let selected = config.days.contains(day)
        return Button {
            if selected { config.days.remove(day) }
            else        { config.days.insert(day) }
        } label: {
            Text(verbatim: "\(day)")
                .font(.subheadline)
                .frame(width: 36, height: 36)
                .background(Circle().fill(selected ? Color.accentColor : Color(.systemGray5)))
                .overlay { if !selected { Circle().stroke(Color(.systemGray3), lineWidth: 0.5) } }
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func monthButton(_ month: Int) -> some View {
        let selected = config.months.contains(month)
        return Button {
            if selected { config.months.remove(month) }
            else        { config.months.insert(month) }
        } label: {
            Text(verbatim: monthSymbol(month))
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(Capsule().fill(selected ? Color.accentColor : Color(.systemGray5)))
                .overlay { if !selected { Capsule().stroke(Color(.systemGray3), lineWidth: 0.5) } }
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func monthSymbol(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        return formatter.shortMonthSymbols[month - 1]
    }
}

#Preview {
    Text("Preview host")
        .sheet(isPresented: .constant(true)) {
            RecurrenceSheet(initialConfig: nil, onSave: { _ in }, onClear: {})
        }
}
