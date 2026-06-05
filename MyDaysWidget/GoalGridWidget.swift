import CoreData
import SwiftUI
import WidgetKit

// MARK: - Home Goal Grid Widget (Small / Medium)
//
// 목표 전용 홈 위젯 — 락스크린 분할 원(SegmentedGoalCircle) + 색상.
//  small  = 2×2 (원 4개), 원당 최대 2분할 → 최대 8개 목표
//  medium = 4×2 (원 8개), 원당 최대 2분할 → 최대 16개 목표
// 분배: 균형 — 목표 적으면 1개씩 풀 원, 많아지면 2분할 (상위 우선순위가 앞 원에).
// 우선순위: 절제 > 활동(auto) > 활동(직접) > 집중 > 습관 (fetchActiveGoalSnapshots).

struct GoalGridEntry: TimelineEntry {
    let date: Date
    /// 표시할 목표 (최대 16 = medium 한계). small은 view에서 8로 prefix.
    let snapshots: [ItemSnapshot]
}

struct GoalGridProvider: TimelineProvider {

    /// medium(4×2 = 8원 × 2분할) 기준 최대.
    static let capacity = 16

    func placeholder(in context: Context) -> GoalGridEntry {
        GoalGridEntry(date: Date(), snapshots: fetch(now: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (GoalGridEntry) -> Void) {
        completion(GoalGridEntry(date: Date(), snapshots: fetch(now: Date())))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GoalGridEntry>) -> Void) {
        let now = Date()
        let items = MyDaysHomeProvider.fetchActiveItems()
        // 홈/락 위젯과 동일 tier — NTD transition 기반 (활동/집중/습관은 시간 전환점 없음).
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
        let entries = dates.sorted().map { date in
            GoalGridEntry(date: date, snapshots: fetch(now: date))
        }
        let reloadAt = (entries.last?.date ?? now).addingTimeInterval(60)
        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }

    private func fetch(now: Date) -> [ItemSnapshot] {
        Array(GoalLockCircleProvider.fetchActiveGoalSnapshots(now: now).prefix(Self.capacity))
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

struct GoalGridEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GoalGridEntry

    /// 한 행의 원 개수 (small 2 / medium 4). 행은 2개 고정.
    private var cols: Int { family == .systemMedium ? 4 : 2 }
    private var slots: Int { cols * 2 }

    var body: some View {
        Group {
            if entry.snapshots.isEmpty {
                emptyView
            } else {
                GoalCirclesView(snapshots: entry.snapshots, cols: cols, rows: 2)
                    .padding(16)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "scope")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("widget.goal_grid.empty")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - GoalCirclesView (재사용 — 단독 목표 위젯 + 조합 위젯)

/// 목표를 cols×rows 그리드의 분할 원으로 표시. 외곽 padding/빈 상태는 호출 측에서 처리.
struct GoalCirclesView: View {
    let snapshots: [ItemSnapshot]
    let cols: Int
    let rows: Int

    var body: some View {
        let slots = cols * rows
        let circles = Self.distribute(Array(snapshots.prefix(slots * 2)), slots: slots)
        var padded = circles
        while padded.count < slots { padded.append([]) }
        // 원 사이 간격은 좁게(2) → 원들이 가운데로 모임.
        return VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<cols, id: \.self) { col in
                        cell(padded[row * cols + col])
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func cell(_ snaps: [ItemSnapshot]) -> some View {
        if snaps.isEmpty {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SegmentedGoalCircle(snapshots: snaps, colored: true)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 목표를 slots개 원에 균형 분배 — 원당 최대 2.
    /// n ≤ slots: 각 1개(풀 원). n > slots: 앞 (n-slots)개 원이 2개, 나머지 1개.
    static func distribute(_ snaps: [ItemSnapshot], slots: Int) -> [[ItemSnapshot]] {
        let n = min(snaps.count, slots * 2)
        guard n > 0 else { return [] }
        let items = Array(snaps.prefix(n))
        let circlesUsed = n <= slots ? n : slots
        let extra = n - circlesUsed  // 2개를 담을 원 수
        var result: [[ItemSnapshot]] = []
        var idx = 0
        for c in 0..<circlesUsed {
            let size = 1 + (c < extra ? 1 : 0)
            result.append(Array(items[idx..<idx + size]))
            idx += size
        }
        return result
    }
}

// MARK: - Widget Configuration

struct GoalGridWidget: Widget {
    let kind: String = "MyDaysGoalGridWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GoalGridProvider()) { entry in
            GoalGridEntryView(entry: entry)
        }
        .configurationDisplayName(Text("widget.goal_grid.display_name"))
        .description(Text("widget.goal_grid.description"))
        .supportedFamilies([.systemSmall, .systemMedium])
        // 시스템 기본 컨텐츠 마진(~16pt) 제거 — 원 그리드가 가장자리까지 차도록.
        // 외곽 여백은 grid의 .padding으로 직접 제어.
        .contentMarginsDisabled()
    }
}

// MARK: - Preview

#Preview("medium", as: .systemMedium) {
    GoalGridWidget()
} timeline: {
    GoalGridEntry(date: .now, snapshots: [
        ItemSnapshot(id: "1", kind: .notTodo, title: "단식", bucket: .ongoing, progress: 0.6, sortAnchor: .now, iconName: "fork.knife", iconColorHex: "blue"),
        ItemSnapshot(id: "2", kind: .activity, title: "걷기", bucket: .ongoing, progress: 0.4, sortAnchor: .now, iconName: "figure.walk", iconColorHex: "green"),
        ItemSnapshot(id: "3", kind: .focus, title: "집중", bucket: .ongoing, progress: 0.8, sortAnchor: .now, iconName: "hourglass.bottomhalf.filled", iconColorHex: "purple"),
        ItemSnapshot(id: "4", kind: .habit, title: "독서", bucket: .ongoing, progress: 0.2, sortAnchor: .now, iconName: "book", iconColorHex: "orange"),
        ItemSnapshot(id: "5", kind: .activity, title: "물", bucket: .ongoing, progress: 0.5, sortAnchor: .now, iconName: "drop", iconColorHex: "teal"),
        ItemSnapshot(id: "6", kind: .notTodo, title: "금주", bucket: .ongoing, progress: 0.9, sortAnchor: .now, iconName: "wineglass", iconColorHex: "red"),
    ])
}

#Preview("small", as: .systemSmall) {
    GoalGridWidget()
} timeline: {
    GoalGridEntry(date: .now, snapshots: [
        ItemSnapshot(id: "1", kind: .notTodo, title: "단식", bucket: .ongoing, progress: 0.6, sortAnchor: .now, iconName: "fork.knife", iconColorHex: "blue"),
        ItemSnapshot(id: "2", kind: .activity, title: "걷기", bucket: .ongoing, progress: 0.4, sortAnchor: .now, iconName: "figure.walk", iconColorHex: "green"),
        ItemSnapshot(id: "3", kind: .focus, title: "집중", bucket: .ongoing, progress: 0.8, sortAnchor: .now, iconName: "hourglass.bottomhalf.filled", iconColorHex: "purple"),
    ])
}
