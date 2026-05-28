import CoreData
import SwiftUI

// MARK: - CategoryListView
//
// Settings에서 진입하는 카테고리 관리 화면.
// - 카테고리 list (icon + name + 항목 수)
// - 우상단 + 버튼 → 신규 생성 sheet
// - row 탭 → 편집 sheet
// - EditMode: 삭제 / 드래그 정렬
//
// 카테고리가 0개여도 화면 노출 (사용자 진입로) — 신규 추가 prompt.

struct CategoryListView: View {

    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Category.sortOrder), SortDescriptor(\Category.createdAt)],
        animation: .default
    )
    private var categories: FetchedResults<Category>

    @State private var sheet: SheetMode?

    private enum SheetMode: Identifiable {
        case new
        case edit(Category)

        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let c): return c.objectID.uriRepresentation().absoluteString
            }
        }
    }

    var body: some View {
        List {
            if categories.isEmpty {
                Text("category.empty")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(categories, id: \.objectID) { cat in
                    // 개별 row를 별도 view + @ObservedObject로 감싸 속성 변경(icon/color 등) 즉시 반영.
                    // FetchedResults 자체는 insert/delete만 publish해서 row 안 속성은 자동 갱신 X.
                    Button {
                        sheet = .edit(cat)
                    } label: {
                        CategoryRowView(category: cat)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteCategories)
                .onMove(perform: moveCategories)
            }
        }
        .navigationTitle("settings.categories")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sheet = .new
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
        }
        .sheet(item: $sheet) { mode in
            switch mode {
            case .new:
                CategoryEditSheet(category: nil)
            case .edit(let cat):
                CategoryEditSheet(category: cat)
            }
        }
    }

    private func deleteCategories(at offsets: IndexSet) {
        for idx in offsets {
            context.delete(categories[idx])
        }
        try? context.save()
    }

    private func moveCategories(from source: IndexSet, to destination: Int) {
        var arr = Array(categories)
        arr.move(fromOffsets: source, toOffset: destination)
        for (idx, cat) in arr.enumerated() {
            cat.sortOrder = Int32(idx)
        }
        try? context.save()
    }
}

/// 카테고리 list의 개별 row. `@ObservedObject`로 Category attribute(icon/color/name) 변경 자동 갱신.
struct CategoryRowView: View {
    @ObservedObject var category: Category

    var body: some View {
        HStack(spacing: 12) {
            // filled circle + white symbol — Apple Reminders 리스트 아이콘 스타일.
            Image(systemName: category.iconName ?? CategoryIcon.defaultIcon.symbolName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Self.categoryColor(for: category)))
            Text(verbatim: category.name ?? "")
                .foregroundStyle(.primary)
            Spacer()
            Text(verbatim: "\(itemCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var itemCount: Int {
        (category.items as? Set<Item>)?.count ?? 0
    }

    static func categoryColor(for cat: Category) -> Color {
        guard let raw = cat.colorHex, let cc = CategoryColor(rawValue: raw) else {
            return .secondary
        }
        return cc.color
    }
}

#Preview {
    NavigationStack { CategoryListView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
