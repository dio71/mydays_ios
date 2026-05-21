import CoreData
import SwiftUI

struct ListView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: ItemSheetMode?
    @State private var showCompleted = false
    @State private var referenceDate = Date()

    @FetchRequest(
        sortDescriptors: [
            SortDescriptor(\Item.priority, order: .reverse),
            SortDescriptor(\Item.dueDate),
            SortDescriptor(\Item.createdAt)
        ],
        predicate: NSPredicate(format: "status == 0 AND isSomeday == NO"),
        animation: .default
    )
    private var activeItems: FetchedResults<Item>

    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Item.completedAt, order: .reverse)],
        predicate: NSPredicate(format: "status == 1 AND isSomeday == NO"),
        animation: .default
    )
    private var completedItems: FetchedResults<Item>

    var body: some View {
        List {
            Section("list.section.active") {
                if activeItems.isEmpty {
                    emptyRow("list.empty.active")
                } else {
                    ForEach(activeItems, id: \.objectID) { rowButton(for: $0) }
                }
            }

            if showCompleted {
                Section("list.section.completed") {
                    if completedItems.isEmpty {
                        emptyRow("list.empty.completed")
                    } else {
                        ForEach(completedItems, id: \.objectID) { rowButton(for: $0) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCompleted.toggle()
                } label: {
                    Image(systemName: showCompleted ? "eye" : "eye.slash")
                }
            }
        }
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

    private func rowButton(for item: Item) -> some View {
        Button {
            sheet = .edit(item)
        } label: {
            ItemRow(
                item: item,
                referenceDate: referenceDate,
                showRoutineDday: true,
                routineCheckable: false
            )
        }
        .buttonStyle(.plain)
    }

    private func emptyRow(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .foregroundStyle(.secondary)
            .font(.subheadline)
    }
}

#Preview {
    NavigationStack { ListView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
