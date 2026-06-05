import CoreData
import SwiftUI
import WidgetKit

// MARK: - Combined Home Widget (Medium / Large)
//
// 왼쪽 = 할일(TodoColumn), 오른쪽 = 목표(GoalCirclesView). 기존 컴포넌트 재사용.
//  medium: 좌 할일 / 우 목표 2×2(원 4, 최대 8개)
//  large : 좌 할일(더 많은 행) / 우 목표 2×4(원 8, 최대 16개)

struct ComboEntry: TimelineEntry {
    let date: Date
    let todos: [ItemSnapshot]
    let goals: [ItemSnapshot]
    let counts: ItemCounts
}

struct ComboProvider: TimelineProvider {

    func placeholder(in context: Context) -> ComboEntry {
        Self.makeEntry(now: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (ComboEntry) -> Void) {
        completion(Self.makeEntry(now: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComboEntry>) -> Void) {
        let now = Date()
        let items = MyDaysHomeProvider.fetchActiveItems()
        // 홈/락 위젯과 동일 tier — NTD transition 기반.
        let transitions = Self.transitionInstants(items: items, after: now)
        let horizon = now.addingTimeInterval(6 * 60 * 60)
        var dates: Set<Date> = [now]
        var t = now
        while t <= horizon {
            let nextT = transitions.first { $0 > t }
            let step: TimeInterval
            if let nt = nextT {
                let ttt = nt.timeIntervalSince(t)
                if ttt > 60 * 60 { step = 60 * 60 }
                else if ttt > 20 * 60 { step = 10 * 60 }
                else if ttt > 5 * 60 { step = 5 * 60 }
                else { step = 60 }
            } else {
                step = 60 * 60
            }
            let next = t.addingTimeInterval(step)
            if let nt = nextT, nt > t && nt < next { dates.insert(nt) }
            t = next
            dates.insert(t)
        }
        let entries = dates.sorted().map { Self.makeEntry(now: $0) }
        let reloadAt = (entries.last?.date ?? now).addingTimeInterval(60)
        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }

    static func makeEntry(now: Date) -> ComboEntry {
        let items = MyDaysHomeProvider.fetchActiveItems()
        return ComboEntry(
            date: now,
            todos: MyDaysHomeProvider.makeSnapshots(items: items, now: now, limit: 16),
            goals: GoalLockCircleProvider.fetchActiveGoalSnapshots(now: now),
            counts: MyDaysHomeProvider.computeCounts(items: items, now: now)
        )
    }

    private static func transitionInstants(items: [Item], after now: Date) -> [Date] {
        var set = Set<TimeInterval>()
        for item in items where item.itemKind == .notTodo {
            guard let occ = item.ntdRelevantOccurrenceDate(at: now) else { continue }
            if let start = item.ntdStartInstant(on: occ), start > now { set.insert(start.timeIntervalSince1970) }
            if let end = item.ntdEndInstant(on: occ), end > now { set.insert(end.timeIntervalSince1970) }
        }
        return set.sorted().map { Date(timeIntervalSince1970: $0) }
    }
}

// MARK: - View

struct ComboEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ComboEntry

    var body: some View {
        let isLarge = family == .systemLarge
        let contentH = isLarge ? TodoLayout.largeContentHeight : TodoLayout.widgetContentHeight
        let todoRows = TodoLayout.fitted(entry.todos, budget: contentH - TodoLayout.headerHeight)
        let goalRows = isLarge ? 4 : 2
        HStack(alignment: .top, spacing: 12) {
            // 왼쪽 — 할일 (헤더 포함).
            TodoColumn(rows: todoRows, date: entry.date, counts: entry.counts, showHeader: true)
            // 오른쪽 — 목표 원 그리드 (2열).
            GoalCirclesView(snapshots: entry.goals, cols: 2, rows: goalRows)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget Configuration

struct ComboWidget: Widget {
    let kind: String = "MyDaysComboWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ComboProvider()) { entry in
            ComboEntryView(entry: entry)
        }
        .configurationDisplayName(Text("widget.combo.display_name"))
        .description(Text("widget.combo.description"))
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Preview

#Preview("medium", as: .systemMedium) {
    ComboWidget()
} timeline: {
    ComboEntry(
        date: .now,
        todos: [
            ItemSnapshot(id: "t1", kind: .todo, title: "팀 점심", bucket: .ongoing, progress: 0, sortAnchor: .now, iconName: "circle", iconColorHex: "blue", timeLabel: "12:00 - 13:00"),
            ItemSnapshot(id: "t2", kind: .todo, title: "리포트 마감", bucket: .ongoing, progress: 0, sortAnchor: .now, iconName: "circle", iconColorHex: "red", timeLabel: nil),
        ],
        goals: [
            ItemSnapshot(id: "g1", kind: .notTodo, title: "단식", bucket: .ongoing, progress: 0.6, sortAnchor: .now, iconName: "fork.knife", iconColorHex: "blue"),
            ItemSnapshot(id: "g2", kind: .activity, title: "걷기", bucket: .ongoing, progress: 0.4, sortAnchor: .now, iconName: "figure.walk", iconColorHex: "green"),
            ItemSnapshot(id: "g3", kind: .habit, title: "독서", bucket: .ongoing, progress: 0.3, sortAnchor: .now, iconName: "book", iconColorHex: "orange"),
        ],
        counts: ItemCounts(goalActive: 3, goalTotal: 3, todoActive: 2, todoTotal: 5)
    )
}

#Preview("large", as: .systemLarge) {
    ComboWidget()
} timeline: {
    ComboEntry(
        date: .now,
        todos: [
            ItemSnapshot(id: "t1", kind: .todo, title: "팀 점심", bucket: .ongoing, progress: 0, sortAnchor: .now, iconName: "circle", iconColorHex: "blue", timeLabel: "12:00 - 13:00"),
            ItemSnapshot(id: "t2", kind: .todo, title: "리포트 마감", bucket: .ongoing, progress: 0, sortAnchor: .now, iconName: "circle", iconColorHex: "red", timeLabel: "18:00 종료"),
            ItemSnapshot(id: "t3", kind: .todo, title: "장보기", bucket: .ongoing, progress: 0, sortAnchor: .now, iconName: "circle", iconColorHex: "green", timeLabel: nil),
        ],
        goals: [
            ItemSnapshot(id: "g1", kind: .notTodo, title: "단식", bucket: .ongoing, progress: 0.6, sortAnchor: .now, iconName: "fork.knife", iconColorHex: "blue"),
            ItemSnapshot(id: "g2", kind: .activity, title: "걷기", bucket: .ongoing, progress: 0.4, sortAnchor: .now, iconName: "figure.walk", iconColorHex: "green"),
            ItemSnapshot(id: "g3", kind: .focus, title: "집중", bucket: .ongoing, progress: 0.8, sortAnchor: .now, iconName: "hourglass.bottomhalf.filled", iconColorHex: "purple"),
            ItemSnapshot(id: "g4", kind: .habit, title: "독서", bucket: .ongoing, progress: 0.2, sortAnchor: .now, iconName: "book", iconColorHex: "orange"),
            ItemSnapshot(id: "g5", kind: .activity, title: "물", bucket: .ongoing, progress: 0.5, sortAnchor: .now, iconName: "drop", iconColorHex: "teal"),
        ],
        counts: ItemCounts(goalActive: 5, goalTotal: 5, todoActive: 3, todoTotal: 8)
    )
}
