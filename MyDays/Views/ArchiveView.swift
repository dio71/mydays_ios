import CoreData
import SwiftUI

struct ArchiveView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: ItemSheetMode?
    @State private var referenceDate = Date()

    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Item.priority, order: .reverse), SortDescriptor(\Item.createdAt)],
        predicate: NSPredicate(format: "isSomeday == YES AND status == 0"),
        animation: .default
    )
    private var items: FetchedResults<Item>

    var body: some View {
        List {
            Section {
                if items.isEmpty {
                    Text("archive.empty")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(items, id: \.objectID) { item in
                        Button {
                            sheet = .edit(item)
                        } label: {
                            ItemRow(item: item, referenceDate: referenceDate)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("archive.title")
        .overlay(alignment: .bottomTrailing) {
            Button {
                sheet = .new(baseDate: nil)
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.accentColor))
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            }
            .padding(20)
        }
        .sheet(item: $sheet) { mode in
            switch mode {
            case .new(let baseDate):
                AddItemView(baseDate: baseDate)
            case .edit(let item):
                AddItemView(editing: item)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                referenceDate = Date()
            }
        }
    }
}

#Preview {
    NavigationStack { ArchiveView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
