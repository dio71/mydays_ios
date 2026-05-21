import SwiftUI

struct RecurrenceSheet: View {

    let initialConfig: RecurrenceConfig?
    let onSave: (RecurrenceConfig) -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var config: RecurrenceConfig

    init(
        initialConfig: RecurrenceConfig?,
        onSave: @escaping (RecurrenceConfig) -> Void,
        onClear: @escaping () -> Void
    ) {
        self.initialConfig = initialConfig
        self.onSave = onSave
        self.onClear = onClear
        self._config = State(initialValue: initialConfig ?? RecurrenceConfig.makeDefault())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("recurrence.frequency.label", selection: $config.frequency) {
                        Text("recurrence.frequency.daily").tag(Frequency.daily)
                        Text("recurrence.frequency.weekly").tag(Frequency.weekly)
                        Text("recurrence.frequency.monthly").tag(Frequency.monthly)
                    }
                    .pickerStyle(.segmented)
                }

                switch config.frequency {
                case .daily:
                    dailySection
                case .weekly:
                    weeklySection
                case .monthly:
                    monthlySection
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
            Stepper(value: $config.interval, in: 1...365) {
                HStack {
                    Text("recurrence.interval.label")
                    Spacer()
                    Text(verbatim: "\(config.interval)")
                        .foregroundStyle(.secondary)
                    Text("recurrence.interval.unit")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - weekly

    private var weeklySection: some View {
        Section("recurrence.weekdays") {
            HStack(spacing: 4) {
                ForEach(weekdayOrder, id: \.self) { w in
                    weekdayButton(w)
                }
            }
            .frame(maxWidth: .infinity)
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

    private var monthlySection: some View {
        Group {
            Section("recurrence.days") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(1...31, id: \.self) { d in
                        dayButton(d)
                    }
                }
                Toggle("recurrence.last_day", isOn: $config.includesLastDay)
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
