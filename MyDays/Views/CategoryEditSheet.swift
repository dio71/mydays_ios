import CoreData
import SwiftUI

// MARK: - CategoryEditSheet
//
// 카테고리 생성/편집 sheet.
// - name TextField
// - color picker (TintPreset 8개 chip)
// - icon picker (CategoryIcon 12개 grid)
// - 저장: 신규면 Category 생성, 기존이면 업데이트
// - 삭제 (편집 모드만, destructive)
//
// 색상은 TintPreset.rawValue 그대로 colorHex 필드에 저장. 렌더 시 변환.

struct CategoryEditSheet: View {

    let category: Category?  // nil = 신규 생성

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var tintRaw: String
    @State private var iconRaw: String
    @State private var showDeleteConfirm = false

    init(category: Category?) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _tintRaw = State(initialValue: category?.colorHex ?? CategoryColor.defaultColor.rawValue)
        _iconRaw = State(initialValue: category?.iconName ?? CategoryIcon.defaultIcon.symbolName)
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
