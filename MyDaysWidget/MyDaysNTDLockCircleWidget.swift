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
    /// nil = 표시할 활성 목표 없음.
    let snapshot: ItemSnapshot?
}

struct GoalLockCircleProvider: TimelineProvider {

    func placeholder(in context: Context) -> GoalLockCircleEntry {
        let now = Date()
        let snaps = Self.fetchActiveGoalSnapshots(now: now)
        return GoalLockCircleEntry(date: now, snapshot: snaps.first)
    }

    func getSnapshot(in context: Context, completion: @escaping (GoalLockCircleEntry) -> Void) {
        let now = Date()
        let snaps = Self.fetchActiveGoalSnapshots(now: now)
        completion(GoalLockCircleEntry(date: now, snapshot: snaps.first))
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
        // LockCircle: index 2부터 회전. LockRect가 top 2를 고정 표시하므로 중복 회피.
        // 활성 목표 ≤ 2개면 빈 상태(rest empty). 3개면 G3 고정, 4개+면 G3, G4, ... 순환.
        let entries: [GoalLockCircleEntry] = sortedDates.enumerated().map { i, entryDate in
            let snaps = Self.fetchActiveGoalSnapshots(now: entryDate)
            let rest = Array(snaps.dropFirst(2))
            let snapshot: ItemSnapshot? = rest.isEmpty ? nil : rest[i % rest.count]
            return GoalLockCircleEntry(date: entryDate, snapshot: snapshot)
        }
        let reloadAt = (entries.last?.date ?? now).addingTimeInterval(60)
        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }

    // MARK: - 활성 목표 fetch (4-type, past 제외)

    /// 진행중/진행예정 bucket 목표만 — 락 위젯은 "지금 신경 써야 할 것" UX.
    /// past(완료/포기/만료)는 락 위젯 노출 가치 낮음 → 제외.
    /// internal — rectangular lock widget이 같은 fetch 재사용.
    static func fetchActiveGoalSnapshots(now: Date) -> [ItemSnapshot] {
        let items = MyDaysHomeProvider.fetchActiveItems()
        let today: Date = .todayCalendarAnchor
        var snaps: [ItemSnapshot] = []
        for item in items where item.itemKind.isGoal {
            if let s = MyDaysHomeProvider.snapshot(for: item, now: now, today: today),
               s.bucket != .past {
                snaps.append(s)
            }
        }
        // 동일 정렬 (bucket → sortAnchor). type 무관 통합 cycle.
        snaps.sort { a, b in
            if a.bucket != b.bucket { return a.bucket < b.bucket }
            return a.sortAnchor < b.sortAnchor
        }
        return snaps
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
        ZStack {
            AccessoryWidgetBackground()
            if let snap = entry.snapshot {
                content(for: snap)
                progressArc(for: snap)
            } else {
                emptyContent
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// 원형 progress arc — 락 위젯 테두리에 호 표시.
    /// 0시(12시 방향) 시작, 시계 방향 fill. 두께 4pt (이전 2pt에서 증가).
    /// scheduled(0%) / past(불노출)도 invisible — fill 0이면 0 호.
    @ViewBuilder
    private func progressArc(for snap: ItemSnapshot) -> some View {
        let progress = max(0, min(snap.progress, 1))
        Circle()
            .trim(from: 0, to: progress)
            .stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(2)
            .widgetAccentable()
    }

    /// 중앙 큰 아이콘 — 시간 정보 제거 → 글랜스용 시각 단순화.
    /// 아이콘 = snap.iconName (GoalIcon symbol 또는 fallback).
    @ViewBuilder
    private func content(for snap: ItemSnapshot) -> some View {
        Image(systemName: snap.iconName)
            .font(.system(size: 22, weight: .medium))
            .widgetAccentable()
    }

    private var emptyContent: some View {
        Image(systemName: "target")
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
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
    GoalLockCircleEntry(
        date: .now,
        snapshot: ItemSnapshot(
            id: "p1", kind: .notTodo, title: "16시간 단식",
            bucket: .ongoing, progress: 0.55,
            sortAnchor: .now.addingTimeInterval(7 * 3600),
            iconName: "fork.knife", iconColorHex: "blue"
        )
    )
    GoalLockCircleEntry(
        date: .now,
        snapshot: ItemSnapshot(
            id: "p2", kind: .focus, title: "집중",
            bucket: .ongoing, progress: 0.4,
            sortAnchor: .now.addingTimeInterval(3600),
            iconName: "hourglass.bottomhalf.filled", iconColorHex: "purple"
        )
    )
    GoalLockCircleEntry(date: .now, snapshot: nil)
}
