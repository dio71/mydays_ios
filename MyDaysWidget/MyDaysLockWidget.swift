import CoreData
import SwiftUI
import WidgetKit

// MARK: - Lock Screen Goal Rectangular Widget
//
// Redesign (2026-06-01):
// - 1칸(circular) 형태 2개 가로 배치 — 큰 아이콘 + 원형 progress arc.
// - 시간 정보 / 제목 없음 — glance용. 사용자가 색·아이콘으로 식별.
// - 활성 목표가 2개 초과 시 rotation: top 2 → next 2 cycle (60초).
//
// 데이터: GoalLockCircleProvider.fetchActiveGoalSnapshots 재활용.

struct GoalLockRectEntry: TimelineEntry {
    let date: Date
    /// 좌·우 슬롯에 표시할 목표 (각 최대 4 분할). 균형 분배 — 총 최대 8.
    let left: [ItemSnapshot]
    let right: [ItemSnapshot]
}

struct GoalLockRectProvider: TimelineProvider {

    /// rectangular 2 slot에 표시할 최대 목표 수 (4분할 × 2).
    static let capacity = 8

    func placeholder(in context: Context) -> GoalLockRectEntry {
        let now = Date()
        let snaps = GoalLockCircleProvider.fetchActiveGoalSnapshots(now: now)
        let (l, r) = Self.split(Array(snaps.prefix(Self.capacity)))
        return GoalLockRectEntry(date: now, left: l, right: r)
    }

    func getSnapshot(in context: Context, completion: @escaping (GoalLockRectEntry) -> Void) {
        let now = Date()
        let snaps = GoalLockCircleProvider.fetchActiveGoalSnapshots(now: now)
        let (l, r) = Self.split(Array(snaps.prefix(Self.capacity)))
        completion(GoalLockRectEntry(date: now, left: l, right: r))
    }

    /// 목표를 좌/우 slot에 균형 분배 — 좌 = ceil(n/2)(최대 4), 우 = 나머지(최대 4).
    /// 2개=각1개(풀 원), 4개=2+2, 8개=4+4. 분할 수를 최소화해 가독성 ↑.
    static func split(_ snaps: [ItemSnapshot]) -> (left: [ItemSnapshot], right: [ItemSnapshot]) {
        let n = min(snaps.count, 8)
        let leftCount = min(4, Int((Double(n) / 2.0).rounded(.up)))
        let left = Array(snaps.prefix(leftCount))
        let right = Array(snaps.dropFirst(leftCount).prefix(4))
        return (left, right)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GoalLockRectEntry>) -> Void) {
        let now = Date()
        let items = MyDaysHomeProvider.fetchActiveItems()
        // Circular과 동일 tier — home widget 패턴.
        let transitions = transitionInstants(items: items, after: now)
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
            if let nt = nextT, nt > t && nt < next {
                dates.insert(nt)
            }
            t = next
            dates.insert(t)
        }
        let sortedDates = dates.sorted()
        // 상위 목표부터 최대 8개를 2 slot에 균형 분배. 8개 초과면 8개씩 window 회전.
        let cap = Self.capacity
        let entries: [GoalLockRectEntry] = sortedDates.enumerated().map { i, entryDate in
            let all = GoalLockCircleProvider.fetchActiveGoalSnapshots(now: entryDate)
            let windows = max(1, Int((Double(all.count) / Double(cap)).rounded(.up)))
            let w = i % windows
            let slice = Array(all.dropFirst(w * cap).prefix(cap))
            let (l, r) = Self.split(slice)
            return GoalLockRectEntry(date: entryDate, left: l, right: r)
        }
        let reloadAt = (entries.last?.date ?? now).addingTimeInterval(60)
        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }

    private func transitionInstants(items: [Item], after now: Date) -> [Date] {
        var set = Set<TimeInterval>()
        for item in items where item.itemKind == .notTodo {
            guard let occ = item.ntdRelevantOccurrenceDate(at: now) else { continue }
            if let start = item.ntdStartInstant(on: occ), start > now {
                set.insert(start.timeIntervalSince1970)
            }
            if let end = item.ntdEndInstant(on: occ), end > now {
                set.insert(end.timeIntervalSince1970)
            }
        }
        return set.sorted().map { Date(timeIntervalSince1970: $0) }
    }
}

// MARK: - View

struct MyDaysLockWidgetEntryView: View {

    let entry: GoalLockRectEntry

    var body: some View {
        Group {
            if entry.left.isEmpty && entry.right.isEmpty {
                emptyContent
            } else {
                HStack(spacing: 8) {
                    slot(entry.left)
                    slot(entry.right)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// 1칸 형태 — 원형 배경 + SegmentedGoalCircle(1~4 분할). 빈 slot은 배경 원만 (시각화 X).
    /// AccessoryWidgetBackground는 부모 family(rectangular)에 맞춰 사각형으로 그려져 원형 시각 깨짐 →
    /// 명시 Circle로 배경 구성.
    @ViewBuilder
    private func slot(_ snaps: [ItemSnapshot]) -> some View {
        ZStack {
            Circle()
                .fill(.fill.tertiary)
            if !snaps.isEmpty {
                SegmentedGoalCircle(snapshots: snaps)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }

    /// 빈 상태 — 중앙 scope 아이콘만 (텍스트 X — circular widget과 통일 시각).
    private var emptyContent: some View {
        Image(systemName: "scope")
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Widget Configuration

struct MyDaysLockWidget: Widget {
    let kind: String = "MyDaysLockWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GoalLockRectProvider()) { entry in
            MyDaysLockWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(Text("widget.ntd_lock.display_name"))
        .description(Text("widget.ntd_lock.description"))
        .supportedFamilies([.accessoryRectangular])
    }
}

// MARK: - Preview

#Preview(as: .accessoryRectangular) {
    MyDaysLockWidget()
} timeline: {
    // 8개 → 좌 4분할 + 우 4분할
    GoalLockRectEntry(
        date: .now,
        left: [
            ItemSnapshot(id: "1", kind: .notTodo, title: "단식", bucket: .ongoing, progress: 0.55,
                         sortAnchor: .now, iconName: "fork.knife", iconColorHex: "blue"),
            ItemSnapshot(id: "2", kind: .activity, title: "걷기", bucket: .ongoing, progress: 0.7,
                         sortAnchor: .now, iconName: "figure.walk", iconColorHex: "green"),
            ItemSnapshot(id: "3", kind: .focus, title: "집중", bucket: .ongoing, progress: 0.3,
                         sortAnchor: .now, iconName: "hourglass.bottomhalf.filled", iconColorHex: "purple"),
            ItemSnapshot(id: "4", kind: .habit, title: "독서", bucket: .scheduled, progress: 0.0,
                         sortAnchor: .now, iconName: "book", iconColorHex: "orange"),
        ],
        right: [
            ItemSnapshot(id: "5", kind: .notTodo, title: "금주", bucket: .ongoing, progress: 0.8,
                         sortAnchor: .now, iconName: "wineglass", iconColorHex: "red"),
            ItemSnapshot(id: "6", kind: .activity, title: "물", bucket: .ongoing, progress: 0.5,
                         sortAnchor: .now, iconName: "drop", iconColorHex: "teal"),
            ItemSnapshot(id: "7", kind: .habit, title: "운동", bucket: .ongoing, progress: 0.25,
                         sortAnchor: .now, iconName: "dumbbell", iconColorHex: "blue"),
        ]
    )
    // 2개 → 각 1개 (풀 원 2개)
    GoalLockRectEntry(
        date: .now,
        left: [ItemSnapshot(id: "a", kind: .notTodo, title: "단식", bucket: .ongoing, progress: 0.55,
                            sortAnchor: .now, iconName: "fork.knife", iconColorHex: "blue")],
        right: [ItemSnapshot(id: "b", kind: .activity, title: "걷기", bucket: .ongoing, progress: 0.3,
                             sortAnchor: .now, iconName: "figure.walk", iconColorHex: "green")]
    )
    GoalLockRectEntry(date: .now, left: [], right: [])
}
