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
    /// 좌·우 슬롯에 표시할 snapshot. 활성 목표 < 2개면 second는 nil.
    let first: ItemSnapshot?
    let second: ItemSnapshot?
}

struct GoalLockRectProvider: TimelineProvider {

    func placeholder(in context: Context) -> GoalLockRectEntry {
        let now = Date()
        let snaps = GoalLockCircleProvider.fetchActiveGoalSnapshots(now: now)
        return GoalLockRectEntry(date: now, first: snaps.first, second: snaps.count > 1 ? snaps[1] : nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (GoalLockRectEntry) -> Void) {
        let now = Date()
        let snaps = GoalLockCircleProvider.fetchActiveGoalSnapshots(now: now)
        completion(GoalLockRectEntry(date: now,
                                     first: snaps.first,
                                     second: snaps.count > 1 ? snaps[1] : nil))
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
        // LockRect: top 2 고정 (회전 없음). LockCircle은 index 2부터 회전하므로 중복 회피.
        // 활성 목표 < 2개면 두 번째 slot은 빈 상태.
        let entries: [GoalLockRectEntry] = sortedDates.map { entryDate in
            let snaps = GoalLockCircleProvider.fetchActiveGoalSnapshots(now: entryDate)
            let first: ItemSnapshot? = snaps.indices.contains(0) ? snaps[0] : nil
            let second: ItemSnapshot? = snaps.indices.contains(1) ? snaps[1] : nil
            return GoalLockRectEntry(date: entryDate, first: first, second: second)
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

struct MyDaysNTDLockWidgetEntryView: View {

    let entry: GoalLockRectEntry

    var body: some View {
        Group {
            if entry.first == nil && entry.second == nil {
                emptyContent
            } else {
                HStack(spacing: 8) {
                    slot(entry.first)
                    slot(entry.second)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// 1칸 형태 — circular widget과 동일 시각 (원형 배경 + 큰 아이콘 + 두꺼운 원형 arc).
    /// AccessoryWidgetBackground는 부모 family(rectangular)에 맞춰 사각형으로 그려져 원형 시각 깨짐 →
    /// 명시 Circle로 배경 구성. clipShape(Circle)도 가능하지만 시스템 tint를 잃어 의도된 시각 손실.
    /// snap nil이면 빈 자리(자리 유지, 시각화 X).
    @ViewBuilder
    private func slot(_ snap: ItemSnapshot?) -> some View {
        ZStack {
            Circle()
                .fill(.fill.tertiary)
            if let snap {
                Image(systemName: snap.iconName)
                    .font(.system(size: 18, weight: .medium))
                    .widgetAccentable()
                Circle()
                    .trim(from: 0, to: max(0, min(snap.progress, 1)))
                    .stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(2)
                    .widgetAccentable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }

    private var emptyContent: some View {
        VStack(alignment: .center, spacing: 4) {
            Image(systemName: "target")
                .font(.system(size: 16))
            Text("widget.ntd.empty")
                .font(.caption2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Widget Configuration

struct MyDaysNTDLockWidget: Widget {
    let kind: String = "MyDaysNTDLockWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GoalLockRectProvider()) { entry in
            MyDaysNTDLockWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(Text("widget.ntd_lock.display_name"))
        .description(Text("widget.ntd_lock.description"))
        .supportedFamilies([.accessoryRectangular])
    }
}

// MARK: - Preview

#Preview(as: .accessoryRectangular) {
    MyDaysNTDLockWidget()
} timeline: {
    GoalLockRectEntry(
        date: .now,
        first: ItemSnapshot(
            id: "p1", kind: .notTodo, title: "16시간 단식",
            bucket: .ongoing, progress: 0.55,
            sortAnchor: .now.addingTimeInterval(7 * 3600),
            iconName: "fork.knife", iconColorHex: "blue"
        ),
        second: ItemSnapshot(
            id: "p2", kind: .activity, title: "걷기",
            bucket: .ongoing, progress: 0.3,
            sortAnchor: .now.addingTimeInterval(8 * 3600),
            iconName: "figure.walk", iconColorHex: "green"
        )
    )
    GoalLockRectEntry(
        date: .now,
        first: ItemSnapshot(
            id: "p3", kind: .focus, title: "집중",
            bucket: .ongoing, progress: 0.7,
            sortAnchor: .now,
            iconName: "hourglass.bottomhalf.filled", iconColorHex: "purple"
        ),
        second: nil
    )
    GoalLockRectEntry(date: .now, first: nil, second: nil)
}
