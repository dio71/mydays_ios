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

    @State private var showStartPicker = false
    @State private var showDuePicker = false
    @State private var showDeleteConfirm = false
    @State private var showPeriod: Bool

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
            _showPeriod = State(initialValue: Self.shouldUsePeriodMode(start: item.startDate, due: item.dueDate))
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
            _priority = State(initialValue: .medium)
            _showPeriod = State(initialValue: false)
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
                    TextField("제목", text: $title)
                        .focused($titleFocused)
                    TextField("메모", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("일정") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            quickChip("오늘", daysFromToday: 0)
                            quickChip("내일", daysFromToday: 1)
                            quickChip("모레", daysFromToday: 2)
                            quickChip("날짜없음", daysFromToday: nil)
                            periodChip
                        }
                        .padding(.vertical, 2)
                    }

                    HStack(spacing: 8) {
                        dateChip(active: hasStart, date: startDate) { showStartPicker = true }
                        if showPeriod {
                            Text("~").foregroundStyle(.secondary)
                            dateChip(active: hasDue, date: dueDate) { showDuePicker = true }
                        }
                        Spacer()
                    }
                }

                Section("우선순위") {
                    Picker("우선순위", selection: $priority) {
                        ForEach(Priority.pickerOrder, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Spacer()
                                Label("삭제", systemImage: "trash")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "할일 수정" : "새 할일")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
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
                    onSelect: { newDate in
                        startDate = newDate
                        hasStart = true
                        if !showPeriod {
                            dueDate = newDate
                            hasDue = true
                        }
                    },
                    onClear: {
                        hasStart = false
                        if !showPeriod {
                            hasDue = false
                        }
                    }
                )
            }
            .sheet(isPresented: $showDuePicker) {
                DatePickerSheet(
                    initialDate: dueDate,
                    onSelect: { newDate in
                        dueDate = newDate
                        hasDue = true
                    },
                    onClear: {
                        hasDue = false
                    }
                )
            }
            .alert("삭제", isPresented: $showDeleteConfirm) {
                Button("취소", role: .cancel) {}
                Button("삭제", role: .destructive) { deleteItem() }
            } message: {
                Text("이 할일을 삭제하시겠어요?")
            }
        }
    }

    private func quickChip(_ title: String, daysFromToday days: Int?) -> some View {
        let active = isQuickChipActive(daysFromToday: days)
        return Button {
            applyQuickDate(daysFromToday: days)
        } label: {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(active ? Color.accentColor : Color.accentColor.opacity(0.15))
                )
                .foregroundStyle(active ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func isQuickChipActive(daysFromToday days: Int?) -> Bool {
        guard let days else {
            return !hasStart && !hasDue
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

    private var periodChip: some View {
        Button {
            let willEnable = !showPeriod
            showPeriod = willEnable
            if !willEnable {
                dueDate = startDate
                hasDue = hasStart
            }
        } label: {
            Text("기간설정")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(showPeriod ? Color.accentColor : Color.accentColor.opacity(0.15))
                )
                .foregroundStyle(showPeriod ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func dateChip(active: Bool, date: Date, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text(active ? formattedDateShort(date) : "날짜 없음")
            }
            .font(.subheadline)
            .foregroundStyle(active ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func formattedDateShort(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        let calendar = Calendar.current
        let dateYear = calendar.component(.year, from: date)
        let currentYear = calendar.component(.year, from: Date())
        formatter.dateFormat = dateYear == currentYear ? "M.d (E)" : "yyyy.M.d (E)"
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
        item.startDate = hasStart ? startDate : nil
        item.dueDate = hasDue ? dueDate : nil
        item.isSomeday = !hasStart && !hasDue
        item.updatedAt = Date()

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
