import CoreData
import SwiftUI

struct AddItemView: View {

    let editingItem: Item?

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool

    @State private var title: String
    @State private var notes: String
    @State private var hasStart: Bool
    @State private var startDate: Date
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @State private var priority: Priority
    @State private var startTimeOfDay: TimeOfDay
    @State private var dueTimeOfDay: TimeOfDay

    @State private var showStartPicker = false
    @State private var showDuePicker = false
    @State private var showDeleteConfirm = false
    @State private var showRecurrenceSheet = false
    @State private var showPeriod: Bool
    @State private var recurrenceConfig: RecurrenceConfig?

    init(editing: Item? = nil, baseDate: Date? = nil) {
        self.editingItem = editing
        if let item = editing {
            _title = State(initialValue: item.title ?? "")
            _notes = State(initialValue: item.notes ?? "")
            _hasStart = State(initialValue: item.startDate != nil)
            _startDate = State(initialValue: item.startDate ?? Calendar.current.startOfDay(for: Date()))
            _hasDue = State(initialValue: item.dueDate != nil)
            _dueDate = State(initialValue: item.dueDate ?? Self.defaultDueDate(after: item.startDate))
            _priority = State(initialValue: item.itemPriority)
            _startTimeOfDay = State(initialValue: item.itemStartTimeOfDay)
            _dueTimeOfDay = State(initialValue: item.itemDueTimeOfDay)
            _showPeriod = State(initialValue: Self.shouldUsePeriodMode(start: item.startDate, due: item.dueDate))
            if let rule = item.recurrenceRule {
                _recurrenceConfig = State(initialValue: RecurrenceConfig(from: rule))
            } else {
                _recurrenceConfig = State(initialValue: nil)
            }
        } else {
            _title = State(initialValue: "")
            _notes = State(initialValue: "")
            if let base = baseDate {
                _hasStart = State(initialValue: true)
                _startDate = State(initialValue: base)
                _hasDue = State(initialValue: true)
                _dueDate = State(initialValue: base)
            } else {
                _hasStart = State(initialValue: false)
                _startDate = State(initialValue: Calendar.current.startOfDay(for: Date()))
                _hasDue = State(initialValue: false)
                _dueDate = State(initialValue: Self.defaultDueDate(after: nil))
            }
            _priority = State(initialValue: .none)
            _startTimeOfDay = State(initialValue: .none)
            _dueTimeOfDay = State(initialValue: .none)
            _showPeriod = State(initialValue: false)
            _recurrenceConfig = State(initialValue: nil)
        }
    }

    private static func shouldUsePeriodMode(start: Date?, due: Date?) -> Bool {
        guard let start, let due else { return false }
        return !Calendar.current.isDate(start, inSameDayAs: due)
    }

    private var isEditing: Bool { editingItem != nil }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

                Section("add.section.schedule") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            quickChip("add.chip.today", daysFromToday: 0)
                            quickChip("add.chip.tomorrow", daysFromToday: 1)
                            quickChip("add.chip.day_after", daysFromToday: 2)
                            quickChip("add.chip.no_date", daysFromToday: nil)
                            periodChip
                        }
                        .padding(.vertical, 2)
                    }

                    HStack(spacing: 8) {
                        dateChip(active: hasStart, date: startDate, timeOfDay: startTimeOfDay) { showStartPicker = true }
                        if showPeriod {
                            Text(verbatim: "~").foregroundStyle(.secondary)
                            dateChip(active: hasDue, date: dueDate, timeOfDay: dueTimeOfDay) { showDuePicker = true }
                        }
                        Spacer()
                    }
                }

                Section("add.section.priority") {
                    HStack(spacing: 12) {
                        ForEach(Priority.pickerOrder, id: \.self) { p in
                            priorityButton(p)
                        }
                        Spacer()
                    }
                }

                Section("add.section.recurrence") {
                    Button {
                        showRecurrenceSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "repeat")
                                .foregroundStyle(recurrenceConfig == nil ? Color.secondary : Color.accentColor)
                            Text(verbatim: recurrenceSummaryText)
                                .foregroundStyle(recurrenceConfig == nil ? Color.secondary : Color.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Spacer()
                                Label("common.delete", systemImage: "trash")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            )
            .navigationTitle(isEditing ? "add.title.edit" : "add.title.new")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { save() }
                        .disabled(!canSave)
                }
            }
            .task {
                guard !isEditing else { return }
                try? await Task.sleep(for: .milliseconds(120))
                titleFocused = true
            }
            .sheet(isPresented: $showStartPicker) {
                DatePickerSheet(
                    initialDate: startDate,
                    initialTimeOfDay: startTimeOfDay,
                    onSelect: { newDate, newTod in
                        startDate = newDate
                        startTimeOfDay = newTod
                        hasStart = true
                        if !showPeriod {
                            dueDate = newDate
                            dueTimeOfDay = newTod
                            hasDue = true
                        }
                    },
                    onClear: {
                        hasStart = false
                        startTimeOfDay = .none
                        if !showPeriod {
                            hasDue = false
                            dueTimeOfDay = .none
                        }
                    }
                )
            }
            .sheet(isPresented: $showDuePicker) {
                DatePickerSheet(
                    initialDate: dueDate,
                    initialTimeOfDay: dueTimeOfDay,
                    onSelect: { newDate, newTod in
                        dueDate = newDate
                        dueTimeOfDay = newTod
                        hasDue = true
                    },
                    onClear: {
                        hasDue = false
                        dueTimeOfDay = .none
                    }
                )
            }
            .sheet(isPresented: $showRecurrenceSheet) {
                RecurrenceSheet(
                    initialConfig: recurrenceConfig,
                    onSave: { config in
                        recurrenceConfig = config
                        ensureStartDateForRecurrence()
                    },
                    onClear: {
                        recurrenceConfig = nil
                    }
                )
            }
            .alert("add.delete_alert.title", isPresented: $showDeleteConfirm) {
                Button("common.cancel", role: .cancel) {}
                Button("common.delete", role: .destructive) { deleteItem() }
            } message: {
                Text("add.delete_alert.message")
            }
        }
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
        let calendar = Calendar.current
        guard let target = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: Date())) else {
            return false
        }
        return calendar.isDate(startDate, inSameDayAs: target)
            && calendar.isDate(dueDate, inSameDayAs: target)
    }

    private func applyQuickDate(daysFromToday days: Int?) {
        guard let days else {
            hasStart = false
            hasDue = false
            startTimeOfDay = .none
            dueTimeOfDay = .none
            showPeriod = false
            return
        }
        let calendar = Calendar.current
        guard let target = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: Date())) else {
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
        startDate = Calendar.current.startOfDay(for: Date())
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
                    Circle().fill(selected ? Color(.systemGray5) : Color.clear)
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
            let willEnable = !showPeriod
            showPeriod = willEnable
            if !willEnable {
                dueDate = startDate
                hasDue = hasStart
                dueTimeOfDay = startTimeOfDay
            }
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

    private func dateChip(active: Bool, date: Date, timeOfDay: TimeOfDay, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                if active {
                    Text(verbatim: dateChipText(date: date, timeOfDay: timeOfDay))
                } else {
                    Text("common.no_date")
                }
            }
            .font(.subheadline)
            .foregroundStyle(active ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func dateChipText(date: Date, timeOfDay: TimeOfDay) -> String {
        let dateStr = formattedDateShort(date)
        return timeOfDay == .none ? dateStr : "\(dateStr) \(timeOfDay.displayName)"
    }

    private func formattedDateShort(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        let calendar = Calendar.current
        let dateYear = calendar.component(.year, from: date)
        let currentYear = calendar.component(.year, from: Date())
        formatter.setLocalizedDateFormatFromTemplate(dateYear == currentYear ? "MdE" : "yMdE")
        return formatter.string(from: date)
    }

    private static func defaultDueDate(after base: Date?) -> Date {
        let calendar = Calendar.current
        let anchor = base.map { calendar.startOfDay(for: $0) } ?? calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: 1, to: anchor) ?? anchor
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNew = editingItem == nil
        let item: Item
        if let existing = editingItem {
            item = existing
        } else {
            item = Item.make(in: context, kind: .todo, title: trimmed, priority: priority)
        }
        item.title = trimmed
        item.notes = notes.isEmpty ? nil : notes
        item.itemPriority = priority
        item.itemStartTimeOfDay = hasStart ? startTimeOfDay : .none
        item.itemDueTimeOfDay = hasDue ? dueTimeOfDay : .none
        item.startDate = hasStart ? startDate : nil
        item.dueDate = hasDue ? dueDate : nil
        item.isSomeday = !hasStart && !hasDue
        item.updatedAt = Date()

        if let config = recurrenceConfig {
            if item.startDate == nil {
                item.startDate = Calendar.current.startOfDay(for: Date())
                item.isSomeday = false
            }
            let rule = item.recurrenceRule ?? RecurrenceRule.make(in: context)
            config.apply(to: rule)
            item.recurrenceRule = rule
        } else if let existing = item.recurrenceRule {
            context.delete(existing)
            item.recurrenceRule = nil
        }

        ItemEvent.log(isNew ? .created : .updated, on: item, in: context)

        do {
            try context.save()
            dismiss()
        } catch {
            assertionFailure("Save failed: \(error)")
        }
    }

    private func deleteItem() {
        guard let item = editingItem else { return }
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
