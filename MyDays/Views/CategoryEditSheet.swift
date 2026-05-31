import CoreData
import SwiftUI

// MARK: - CategoryEditSheet
//
// 카테고리 생성/편집 sheet.
// - name TextField
// - color picker (CategoryColor 8개 chip)
// - icon picker (CategoryIcon grid)
// - NTD 기본 카테고리 토글 (다른 카테고리와 exclusive — 1개만 ON 가능)
// - 알림 default — NTD 시작/종료 + Todo timed/untimed-start/untimed-due 총 5종 menu picker
// - 저장: 신규면 Category 생성, 기존이면 업데이트
// - 삭제 (편집 모드만, destructive)
//
// 색상은 CategoryColor.rawValue 그대로 colorHex 필드에 저장. 렌더 시 변환.
// 알림 default offset(분)은 NSNumber? (nil=OFF). 신규 생성 시 NTD start/due=0(정각),
// Todo 3종=nil(미설정).

struct CategoryEditSheet: View {

    let category: Category?  // nil = 신규 생성

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var tintRaw: String
    @State private var iconRaw: String

    // 알림 default — offset(분). nil = OFF. Todo 4종(timed/untimed × start/due)만.
    @State private var todoTimedStartAlert: Int?
    @State private var todoTimedDueAlert: Int?
    @State private var todoUntimedStartAlert: Int?
    @State private var todoUntimedDueAlert: Int?

    @State private var showDeleteConfirm = false

    init(category: Category?) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _tintRaw = State(initialValue: category?.colorHex ?? CategoryColor.defaultColor.rawValue)
        _iconRaw = State(initialValue: category?.iconName ?? CategoryIcon.defaultIcon.symbolName)
        _todoTimedStartAlert = State(initialValue: category?.defaultTodoTimedStartAlertInt)
        _todoTimedDueAlert = State(initialValue: category?.defaultTodoTimedDueAlertInt)
        _todoUntimedStartAlert = State(initialValue: category?.defaultTodoUntimedStartAlertInt)
        _todoUntimedDueAlert = State(initialValue: category?.defaultTodoUntimedDueAlertInt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("category.field.name", text: $name)
                }

                Section("category.section.color") {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8),
                        spacing: 8
                    ) {
                        ForEach(CategoryColor.allCases) { cc in
                            colorChip(cc)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("category.section.icon") {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6),
                        spacing: 8
                    ) {
                        ForEach(CategoryIcon.allCases) { icon in
                            iconChip(icon)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("category.section.alert_default.todo") {
                    alertOffsetPicker(
                        label: "category.alert.todo_timed_start",
                        selection: $todoTimedStartAlert,
                        options: AlertOffset.withTimeOptions
                    )
                    alertOffsetPicker(
                        label: "category.alert.todo_untimed_start",
                        selection: $todoUntimedStartAlert,
                        options: AlertOffset.noTimeOptions
                    )
                    alertOffsetPicker(
                        label: "category.alert.todo_timed_due",
                        selection: $todoTimedDueAlert,
                        options: AlertOffset.withTimeOptions
                    )
                    alertOffsetPicker(
                        label: "category.alert.todo_untimed_due",
                        selection: $todoUntimedDueAlert,
                        options: AlertOffset.noTimeOptions
                    )
                }

                if category != nil {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("common.delete", systemImage: "trash")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .alert("category.delete_alert.title", isPresented: $showDeleteConfirm) {
                            Button("common.cancel", role: .cancel) {}
                            Button("common.delete", role: .destructive) { deleteCategory() }
                        } message: {
                            Text("category.delete_alert.message")
                        }
                    }
                }
            }
            .navigationTitle(category == nil ? "category.new" : "category.edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .tint(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .appTint()
    }

    @ViewBuilder
    private func colorChip(_ cc: CategoryColor) -> some View {
        let selected = tintRaw == cc.rawValue
        Button {
            tintRaw = cc.rawValue
        } label: {
            Circle()
                .fill(cc.color)
                .frame(width: 30, height: 30)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .accessibilityLabel(Text(cc.labelKey))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func iconChip(_ icon: CategoryIcon) -> some View {
        let selected = iconRaw == icon.symbolName
        let color = CategoryColor(rawValue: tintRaw)?.color ?? .accentColor
        Button {
            iconRaw = icon.symbolName
        } label: {
            Image(systemName: icon.symbolName)
                .font(.body)
                .frame(width: 36, height: 36)
                .background(Circle().fill(selected ? color : Color(.systemGray5)))
                .overlay {
                    if !selected {
                        Circle().stroke(Color(.systemGray3), lineWidth: 0.5)
                    }
                }
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    /// 알림 offset menu picker — "안 함" + offset 옵션. selection은 Int? (nil=OFF).
    private func alertOffsetPicker(
        label: LocalizedStringKey,
        selection: Binding<Int?>,
        options: [Int]
    ) -> some View {
        Picker(selection: selection) {
            Text("alert.offset.disabled").tag(Optional<Int>.none)
            ForEach(options, id: \.self) { offset in
                Text(verbatim: AlertOffset.label(for: offset)).tag(Optional(offset))
            }
        } label: {
            Text(label)
        }
        .pickerStyle(.menu)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target = category ?? Category(context: context)
        let now = Date()
        if category == nil {
            target.id = UUID()
            target.createdAt = now
            // 새 카테고리는 list 끝에 추가 — 기존 max sortOrder + 1.
            let req: NSFetchRequest<Category> = Category.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: false)]
            req.fetchLimit = 1
            let maxOrder = (try? context.fetch(req).first?.sortOrder) ?? -1
            target.sortOrder = maxOrder + 1
        }
        target.name = trimmed
        target.colorHex = tintRaw
        target.iconName = iconRaw
        target.updatedAt = now
        // 알림 default — Todo 4종만 (목표는 카테고리 사용 안 함).
        target.defaultTodoTimedStartAlertInt = todoTimedStartAlert
        target.defaultTodoTimedDueAlertInt = todoTimedDueAlert
        target.defaultTodoUntimedStartAlertInt = todoUntimedStartAlert
        target.defaultTodoUntimedDueAlertInt = todoUntimedDueAlert
        do {
            try context.save()
        } catch {
            assertionFailure("Category save failed: \(error)")
        }
        dismiss()
    }

    private func deleteCategory() {
        guard let cat = category else { return }
        context.delete(cat)
        try? context.save()
        dismiss()
    }
}

#Preview {
    Text("Preview host")
        .sheet(isPresented: .constant(true)) {
            CategoryEditSheet(category: nil)
                .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
        }
}
