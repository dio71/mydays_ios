import CoreData
import SwiftUI
import WidgetKit

// MARK: - Lock Screen Goal Circular Widget
//
// Redesign (2026-06-01):
// - 시간 정보 제거 → center에 큰 목표 아이콘 + 두꺼운 원형 progress arc.
// - 목표 4-type 통합 (절제/활동/집중/습관). 활성 목표만 표시.
// - 활성 목표가 여러 개면 60초 cycle rotation.
//
// 데이터 소스: MyDaysWidget의 Provider 로직 재활용 — 목표 한정 fetch + bucket 분류.
// rotation 패턴은 lock rectangular와 동일하지만 entries는 각자 timeline 발급.

struct GoalLockCircleEntry: TimelineEntry {
    let date: Date
    /// 표시할 활성 목표 (0~4). 비면 빈 상태. 2개 이상이면 원을 분할해 동시 표시.
    let snapshots: [ItemSnapshot]
}

struct GoalLockCircleProvider: TimelineProvider {

    /// 원 1개에 표시할 최대 목표 수 (4분할).
    static let capacity = 4

    func placeholder(in context: Context) -> GoalLockCircleEntry {
        let now = Date()
        let snaps = Self.fetchActiveGoalSnapshots(now: now)
        return GoalLockCircleEntry(date: now, snapshots: Array(snaps.prefix(Self.capacity)))
    }

    func getSnapshot(in context: Context, completion: @escaping (GoalLockCircleEntry) -> Void) {
        let now = Date()
        let snaps = Self.fetchActiveGoalSnapshots(now: now)
        completion(GoalLockCircleEntry(date: now, snapshots: Array(snaps.prefix(Self.capacity))))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GoalLockCircleEntry>) -> Void) {
        let now = Date()
        let items = MyDaysHomeProvider.fetchActiveItems()
        // Adaptive tier — home widget과 동일.
        //   >1h 60min / 20m~1h 10min / 5m~20m 5min / <5m 1min / 미설정 60min.
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
            if let nt = nextT, nt > t && nt < next {
                dates.insert(nt)
            }
            t = next
            dates.insert(t)
        }
        let sortedDates = dates.sorted()
        // 상위 목표부터 최대 4개를 한 원에 분할 표시 (1=풀/2=좌우/3=삼각/4=사분면).
        // 4개 초과면 4개씩 window로 회전 (entry tier step마다 다음 window).
        let cap = Self.capacity
        let entries: [GoalLockCircleEntry] = sortedDates.enumerated().map { i, entryDate in
            let all = Self.fetchActiveGoalSnapshots(now: entryDate)
            let windows = max(1, Int((Double(all.count) / Double(cap)).rounded(.up)))
            let w = i % windows
            let slice = Array(all.dropFirst(w * cap).prefix(cap))
            return GoalLockCircleEntry(date: entryDate, snapshots: slice)
        }
        let reloadAt = (entries.last?.date ?? now).addingTimeInterval(60)
        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }

    // MARK: - 활성 목표 fetch (4-type, past 제외)

    /// 진행중/진행예정 bucket 목표만 — 락 위젯은 "지금 신경 써야 할 것" UX.
    /// past(완료/포기/만료)는 락 위젯 노출 가치 낮음 → 제외.
    /// internal — rectangular lock widget이 같은 fetch 재사용.
    /// **모든 목표 4-type 표시** (절제/활동/집중/습관). 우선순위: 절제 > 활동(auto) > 활동(직접) > 집중 > 습관.
    /// - 직접 입력 활동/집중/습관: 실시간 갱신은 안 되지만 마지막 진행값 표시 (앱 진입/HK BG 시 reload).
    static func fetchActiveGoalSnapshots(now: Date) -> [ItemSnapshot] {
        let items = MyDaysHomeProvider.fetchActiveItems()
        let today: Date = .todayCalendarAnchor
        var ranked: [(rank: Int, snap: ItemSnapshot)] = []
        for item in items {
            guard item.itemKind.isGoal else { continue }
            guard let s = MyDaysHomeProvider.snapshot(for: item, now: now, today: today),
                  s.bucket != .past else { continue }
            ranked.append((goalTypeRank(item), s))
        }
        // 1순위 타입 우선순위 → 2순위 bucket(진행중<예정) → 3순위 sortAnchor.
        ranked.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.snap.bucket != b.snap.bucket { return a.snap.bucket < b.snap.bucket }
            return a.snap.sortAnchor < b.snap.sortAnchor
        }
        return ranked.map { $0.snap }
    }

    /// 목표 타입 우선순위 — 절제(0) > 활동 auto(1) > 활동 직접(2) > 집중(3) > 습관(4).
    private static func goalTypeRank(_ item: Item) -> Int {
        switch item.itemKind {
        case .notTodo: return 0
        case .activity: return item.activitySource == .manual ? 2 : 1
        case .focus: return 3
        case .habit: return 4
        default: return 5
        }
    }

    private static func transitionInstants(items: [Item], after now: Date) -> [Date] {
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

struct MyDaysNTDLockCircleWidgetEntryView: View {
    let entry: GoalLockCircleEntry

    var body: some View {
        // ZStack에 AccessoryWidgetBackground — 캘린더 위젯과 동일한 원형 배경.
        // 시스템이 잠금화면 tint를 자동 적용 → background는 secondary, widgetAccentable 영역은 강조.
        // SegmentedGoalCircle이 1~4 분할 + 빈 상태까지 처리.
        ZStack {
            AccessoryWidgetBackground()
            SegmentedGoalCircle(snapshots: entry.snapshots)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget Configuration

struct MyDaysNTDLockCircleWidget: Widget {
    let kind: String = "MyDaysNTDLockCircleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GoalLockCircleProvider()) { entry in
            MyDaysNTDLockCircleWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(Text("widget.ntd_lock_circle.display_name"))
        .description(Text("widget.ntd_lock_circle.description"))
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - Preview

#Preview(as: .accessoryCircular) {
    MyDaysNTDLockCircleWidget()
} timeline: {
    // 4분할
    GoalLockCircleEntry(date: .now, snapshots: [
        ItemSnapshot(id: "p1", kind: .notTodo, title: "단식", bucket: .ongoing, progress: 0.55,
                     sortAnchor: .now, iconName: "fork.knife", iconColorHex: "blue"),
        ItemSnapshot(id: "p2", kind: .activity, title: "걷기", bucket: .ongoing, progress: 0.7,
                     sortAnchor: .now, iconName: "figure.walk", iconColorHex: "green"),
        ItemSnapshot(id: "p3", kind: .focus, title: "집중", bucket: .ongoing, progress: 0.3,
                     sortAnchor: .now, iconName: "hourglass.bottomhalf.filled", iconColorHex: "purple"),
        ItemSnapshot(id: "p4", kind: .habit, title: "독서", bucket: .scheduled, progress: 0.0,
                     sortAnchor: .now, iconName: "book", iconColorHex: "orange"),
    ])
    // 1분할 (풀 원)
    GoalLockCircleEntry(date: .now, snapshots: [
        ItemSnapshot(id: "s1", kind: .notTodo, title: "단식", bucket: .ongoing, progress: 0.55,
                     sortAnchor: .now, iconName: "fork.knife", iconColorHex: "blue"),
    ])
    GoalLockCircleEntry(date: .now, snapshots: [])
}
