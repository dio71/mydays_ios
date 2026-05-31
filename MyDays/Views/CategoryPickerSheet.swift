import CoreData
import SwiftUI

// MARK: - CategoryPickerSheet
//
// 카테고리 선택 sheet. AddItemView의 카테고리 row 탭 시 노출.
// - 옵션: "없음" + 등록된 모든 카테고리 (icon + name)
// - 각 옵션은 filled circle + white symbol 스타일 (CategoryListView와 동일)
// - 탭 시 즉시 선택 + dismiss
// - 현재 선택 항목에는 우측 체크마크

struct CategoryPickerSheet: View {

    @Binding var selectedID: UUID?
    let categories: [Category]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // "없음" 옵션
                Button {
                    selectedID = nil
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "circle.slash")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.secondary))
                        Text("category.none")
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedID == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // 등록된 카테고리들
                ForEach(categories, id: \.objectID) { cat in
                    Button {
                        selectedID = cat.id
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: cat.iconName ?? CategoryIcon.defaultIcon.symbolName)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(CategoryRowView.categoryColor(for: cat)))
                            Text(verbatim: cat.name ?? "")
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedID == cat.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("add.field.category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") { dismiss() }
                        .tint(.secondary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .appTint()
    }
}
