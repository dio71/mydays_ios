import CoreData
import SwiftUI
import WidgetKit

// MARK: - Lock Screen NTD Circular Widget
//
// 잠금화면 accessoryCircular widget — 자동으로 가장 임박한 NTD 표시.
// 보통 사용자는 NTD 1개만 진행하므로 별도 picker 없이 most relevant NTD 자동 선택.
// 여러 NTD가 동시 진행 중이면 rectangular와 동일한 60초 회전.
//
// 데이터 소스 + 정렬 + 회전 로직은 MyDaysNTDLockWidget(NTDLockProvider)와 동일 패턴 — 공유 helper 재사용.

struct NTDLockCircleEntry: TimelineEntry {
    let date: Date
    let snapshot: ItemSnapshot?
}

struct NTDLockCircleProvider: TimelineProvider {

    func placeholder(in context: Context) -> NTDLockCircleEntry {
        let now = Date()
        let snaps = NTDLockProvider.fetchRelevantNTDSnapshots(now: now)
        return NTDLockCircleEntry(date: now, snapshot: snaps.first)
    }

    func getSnapshot(in context: Context, completion: @escaping (NTDLockCircleEntry) -> Void) {
        let now = Date()
        let snaps = NTDLockProvider.fetchRelevantNTDSnapshots(now: now)
        completion(NTDLockCircleEntry(date: now, snapshot: snaps.first))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NTDLockCircleEntry>) -> Void) {
        let now = Date()
        // Rectangular와 동일 tiered granularity:
        //   >3h 30m step / 3h~1h 10m step / 1h~20m 5m step / <20m 1m step / 미설정 1h.
        let activeSnaps = NTDLockProvider.fetchRelevantNTDSnapshots(now: now)
        var transitions: [Date] = []
        for snap in activeSnaps {
            if snap.startInstant > now { transitions.append(snap.startInstant) }
            if let end = snap.endInstant, end > now { transitions.append(end) }
        }
        let horizon = now.addingTimeInterval(6 * 60 * 60)
        var dates: Set<Date> = []
        var t = now
        while t <= horizon {
            dates.insert(t)
            let nextT = transitions.filter { $0 > t }.min()
            let step: TimeInterval
            if let nt = nextT {
                let ttt = nt.timeIntervalSince(t)
                if ttt > 3 * 60 * 60 { step = 30 * 60 }
                else if ttt > 60 * 60 { step = 10 * 60 }
                else if ttt > 20 * 60 { step = 5 * 60 }
                else { step = 60 }
            } else {
                step = 60 * 60
            }
            let next = t.addingTimeInterval(step)
            if let nt = nextT, nt > t && nt < next {
                dates.insert(nt)
            }
            t = next
        }
        let sortedDates = dates.sorted()
        let entries: [NTDLockCircleEntry] = sortedDates.enumerated().map { i, entryDate in
            let snaps = NTDLockProvider.fetchRelevantNTDSnapshots(now: entryDate)
            let snapshot: ItemSnapshot? = snaps.isEmpty ? nil : snaps[i % snaps.count]
            return NTDLockCircleEntry(date: entryDate, snapshot: snapshot)
        }
        let reloadAt = (entries.last?.date ?? now).addingTimeInterval(60)
        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }
}

// MARK: - View

struct MyDaysNTDLockCircleWidgetEntryView: View {
    let entry: NTDLockCircleEntry

    var body: some View {
        // ZStack에 AccessoryWidgetBackground를 깔아 캘린더 위젯과 같은 원형 배경 효과.
        // 시스템이 잠금화면 tint를 자동 적용 — 배경 원은 secondary, widgetAccentable() 영역은 강조.
        // 진행 중일 때만 테두리에 progress arc (Circle.trim) 오버레이.
        ZStack {
            AccessoryWidgetBackground()
            if let snap = entry.snapshot {
                content(for: snap)
                if snap.state == .inProgress {
                    progressArc(for: snap)
                }
            } else {
                emptyContent
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// 진행 중 NTD의 progress arc — 위젯 테두리에 원형 호로 진행도 표시.
    /// 0시 방향(12시) 시작, 시계 방향으로 fill.
    /// - 목표 시간 설정: elapsed / total
    /// - 목표 시간 미설정: elapsed / 30일, cap 1.0
    /// 대기(scheduled)/완료/포기 상태에서는 본 view 자체가 호출되지 않음.
    /// entry.date 기준 1회 render — Lock Screen TimelineView 갱신 제약 회피, transition entry로 라이프사이클 처리.
    @ViewBuilder
    private func progressArc(for snap: ItemSnapshot) -> some View {
        Circle()
            .trim(from: 0, to: Self.progressValue(for: snap, now: entry.date))
            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(1)
            .widgetAccentable()
    }

    /// 진행도 0.0~1.0. 목표 시간 있으면 elapsed/total, 없으면 30일 기준 cap.
    static func progressValue(for snap: ItemSnapshot, now: Date) -> Double {
        guard snap.state == .inProgress else { return 0 }
        let elapsed = now.timeIntervalSince(snap.startInstant)
        if let end = snap.endInstant {
            let total = max(end.timeIntervalSince(snap.startInstant), 1)
            return max(0, min(elapsed / total, 1.0))
        }
        // 목표 시간 미설정 — 30일 기준 (이후로는 100%로 cap).
        let thirtyDays: TimeInterval = 30 * 24 * 3600
        return max(0, min(elapsed / thirtyDays, 1.0))
    }

    /// 3단 stack — icon / HH:mm 카운트다운(크게) / 상태 라벨(작게).
    /// countdown은 widgetAccentable로 강조, 아이콘/라벨은 secondary 톤.
    @ViewBuilder
    private func content(for snap: ItemSnapshot) -> some View {
        VStack(spacing: 0) {
            // 카테고리 설정 시 카테고리 아이콘, 미설정 시 clock fallback.
            // 잠금화면 monochrome — 색은 시스템 tint(widgetAccentable 영역 외 secondary).
            Image(systemName: snap.categoryIconName ?? "clock")
                .font(.system(size: 10))
            countdownTimeline(for: snap)
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .widgetAccentable()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
            statusLabel(for: snap)
                .font(.system(size: 9, weight: .medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyContent: some View {
        Image(systemName: "clock")
            .font(.system(size: 20))
            .widgetAccentable()
    }

    /// 카운트다운 — 단위 명시 포맷 (예: "20분" / "16시간" / "5일"). entry.date 기준 미리 계산.
    /// Provider가 분 granularity 별 entry 발급 → iOS entry swap으로 갱신 (Lock Screen TimelineView 제약 회피).
    /// 좁은 원형 영역이라 minimumScaleFactor + multilineTextAlignment center가 처리.
    @ViewBuilder
    private func countdownTimeline(for snap: ItemSnapshot) -> some View {
        Text(verbatim: MyDaysNTDLockWidgetEntryView.formatDuration(for: snap, now: entry.date))
    }

    /// 좁은 공간 위한 짧은 라벨 (남음/진행/대기 / Left/On/Wait).
    private func statusLabel(for snap: ItemSnapshot) -> Text {
        switch snap.state {
        case .scheduled:
            return Text("widget.ntd_lock_circle.status.scheduled")
        case .inProgress:
            return snap.endInstant != nil
                ? Text("widget.ntd_lock_circle.status.remaining")
                : Text("widget.ntd_lock_circle.status.elapsed")
        case .overdue, .untimed:
            return Text(verbatim: "")
        }
    }

}

// MARK: - Widget Configuration

struct MyDaysNTDLockCircleWidget: Widget {
    let kind: String = "MyDaysNTDLockCircleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NTDLockCircleProvider()) { entry in
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
    NTDLockCircleEntry(
        date: .now,
        snapshot: ItemSnapshot(
            kind: .notTodo, isRoutine: false,
            title: "16시간 단식",
            priority: .high, state: .inProgress,
            startInstant: .now.addingTimeInterval(-3600),
            endInstant: .now.addingTimeInterval(5 * 3600 + 30 * 60),
            categoryIconName: nil, categoryColorHex: nil
        )
    )
    NTDLockCircleEntry(date: .now, snapshot: nil)
}
