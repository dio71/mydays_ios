import CoreData
import SwiftUI

struct ArchiveView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: ItemSheetMode?
    @State private var entryText: String = ""
    @State private var showCompleted = false
    // ArchiveView는 isSomeday=true 항목만 보여주므로 사실상 referenceDate 영향 작지만,
    // 일관성을 위해 UTC anchor로 통일.
    @State private var referenceDate: Date = .todayCalendarAnchor

    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Item.priority, order: .reverse), SortDescriptor(\Item.createdAt)],
        predicate: NSPredicate(format: "isSomeday == YES AND status == 0"),
        animation: .default
    )
    private var items: FetchedResults<Item>

    // 완료/취소 보관함 항목 — status 1(done) OR 3(failed).
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Item.completedAt, order: .reverse)],
        predicate: NSPredicate(format: "isSomeday == YES AND (status == 1 OR status == 3)"),
        animation: .default
    )
    private var completedItems: FetchedResults<Item>

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

            if showCompleted {
                Section("list.section.completed") {
                    if completedItems.isEmpty {
                        Text("list.empty.completed")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(completedItems, id: \.objectID) { item in
                            Button {
                                sheet = .edit(item)
                            } label: {
                                ItemRow(item: item, referenceDate: referenceDate, mode: .list)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("archive.title")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCompleted.toggle()
                } label: {
                    Image(systemName: showCompleted ? "checklist" : "checklist.unchecked")
                }
            }
        }
        // 마지막 row가 입력 바에 가리지 않도록 스크롤 여백 확보 (입력 바 높이 + margin).
        .contentMargins(.bottom, 96, for: .scrollContent)
        // 하단 inline 입력 바 — overlay로 고정 위치 (탭 이동 시 위치 흔들림 방지).
        // safeAreaInset과 달리 overlay는 키보드 표시 시에도 자동으로 위로 올라옴 (iOS 기본 keyboard avoidance).
        .overlay(alignment: .bottom) {
            QuickEntryBar(
                text: $entryText,
                onSubmit: quickSave,
                onEmptyTap: { sheet = .new(baseDate: nil) }
            )
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
                referenceDate = .todayCalendarAnchor
            }
        }
    }

    /// 보관함 즉시 등록 — 제목만 받고 isSomeday=true로 저장. 나중에 탭해서 상세 편집.
    /// text reset은 QuickEntryBar가 책임짐.
    private func quickSave() {
        let title = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let item = Item.make(in: context, kind: .todo, title: title)
        item.isSomeday = true
        ItemEvent.log(.created, on: item, in: context)
        do {
            try context.save()
        } catch {
            assertionFailure("Quick save failed: \(error)")
        }
    }
}

#Preview {
    NavigationStack { ArchiveView() }
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
