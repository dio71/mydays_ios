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
        // Rectangular와 동일 패턴 — 60초 주기로 round-robin, 30분 window.
        // NTD가 1개면 매 entry가 같은 항목 → 회전 없는 효과.
        var entries: [NTDLockCircleEntry] = []
        for i in 0..<Self.maxEntries {
            let entryDate = now.addingTimeInterval(TimeInterval(i) * Self.rotationInterval)
            let snaps = NTDLockProvider.fetchRelevantNTDSnapshots(now: entryDate)
            let snapshot: ItemSnapshot? = snaps.isEmpty ? nil : snaps[i % snaps.count]
            entries.append(NTDLockCircleEntry(date: entryDate, snapshot: snapshot))
        }
        let reloadAt = (entries.last?.date ?? now).addingTimeInterval(Self.rotationInterval)
        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }

    private static let rotationInterval: TimeInterval = 60
    private static let maxEntries = 30
}

// MARK: - View

struct MyDaysNTDLockCircleWidgetEntryView: View {
    let entry: NTDLockCircleEntry

    var body: some View {
        // ZStack에 AccessoryWidgetBackground를 깔아 캘린더 위젯과 같은 원형 배경 효과.
        // 시스템이 잠금화면 tint를 자동 적용 — 배경 원은 secondary, widgetAccentable() 영역은 강조.
        ZStack {
            AccessoryWidgetBackground()
            if let snap = entry.snapshot {
                content(for: snap)
            } else {
                emptyContent
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// 3단 stack — icon / HH:mm 카운트다운(크게) / 상태 라벨(작게).
    /// countdown은 widgetAccentable로 강조, 아이콘/라벨은 secondary 톤.
    @ViewBuilder
    private func content(for snap: ItemSnapshot) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "stopwatch")
                .font(.system(size: 10))
            countdownTimeline(for: snap)
                .font(.system(size: 18, weight: .bold))
                .monospacedDigit()
                .widgetAccentable()
            statusLabel(for: snap)
                .font(.system(size: 9, weight: .medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyContent: some View {
        Image(systemName: "stopwatch")
            .font(.system(size: 20))
            .widgetAccentable()
    }

    /// HH:mm 형식 카운트다운. 분 단위 갱신.
    @ViewBuilder
    private func countdownTimeline(for snap: ItemSnapshot) -> some View {
        let now = Date()
        TimelineView(.periodic(from: now, by: 60)) { context in
            let secs = MyDaysNTDLockWidgetEntryView.remainingSeconds(for: snap, now: context.date)
            Text(verbatim: Self.formatHHMM(seconds: secs))
        }
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

    /// "H:mm" 포맷. < 1분이면 "0:01"로 floor (초 노출 회피).
    /// >= 24h여도 total hours로 표시 (예: "125:30") — NTD는 보통 16h 단식 등이라 24h 미만이 일반적.
    static func formatHHMM(seconds: Int) -> String {
        let s = max(0, seconds)
        let totalMinutes = s < 60 ? 1 : s / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return String(format: "%d:%02d", hours, minutes)
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
            endInstant: .now.addingTimeInterval(5 * 3600 + 30 * 60)
        )
    )
    NTDLockCircleEntry(date: .now, snapshot: nil)
}
