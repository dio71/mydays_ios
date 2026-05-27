import CoreData
import SwiftUI
import WidgetKit

// MARK: - Lock Screen NTD Widget
//
// 잠금화면 accessoryRectangular widget — 가장 relevant한 NTD occurrence 1개만 표시.
// 홈 위젯(MyDaysWidget)과 별도 widget kind:
//   - 잠금화면은 monochrome + vibrancy 환경. 색·배경 통제 불가 → widgetAccentable로 강조만.
//   - 단일 NTD에 집중 — 잠금화면 glance UX (5초 이내 정보 파악).
//   - Text(timerInterval:countsDown:) 사용 — OS가 매초 자동 갱신해 TimelineView 불필요.
//
// Provider는 NTD-only fetch + 1개 선택. 홈 위젯의 fetchActiveItems는 NTD/Todo 통합이라
// 잠금 widget process에서 불필요한 메모리를 쓸 이유 없음.

struct NTDLockEntry: TimelineEntry {
    let date: Date
    /// nil이면 표시할 NTD 없음 (빈 상태).
    let snapshot: ItemSnapshot?
}

struct NTDLockProvider: TimelineProvider {

    func placeholder(in context: Context) -> NTDLockEntry {
        // iOS 26+ widget placeholder는 real data 반환 필수 (빈 entry면 stuck).
        let now = Date()
        let snaps = Self.fetchRelevantNTDSnapshots(now: now)
        return NTDLockEntry(date: now, snapshot: snaps.first)
    }

    func getSnapshot(in context: Context, completion: @escaping (NTDLockEntry) -> Void) {
        let now = Date()
        let snaps = Self.fetchRelevantNTDSnapshots(now: now)
        completion(NTDLockEntry(date: now, snapshot: snaps.first))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NTDLockEntry>) -> Void) {
        let now = Date()
        // 활성 NTD 여러 개면 rotationInterval 마다 round-robin으로 교체.
        // 각 entry는 그 시점 기준으로 list를 다시 평가 → window 안에서 transition(시작/종료)이 발생해도
        // 다음 entry가 새 list를 반영함. snapshot은 view layer의 TimelineView가 분 단위로 countdown 갱신.
        var entries: [NTDLockEntry] = []
        for i in 0..<Self.maxEntries {
            let entryDate = now.addingTimeInterval(TimeInterval(i) * Self.rotationInterval)
            let snaps = Self.fetchRelevantNTDSnapshots(now: entryDate)
            let snapshot: ItemSnapshot? = snaps.isEmpty ? nil : snaps[i % snaps.count]
            entries.append(NTDLockEntry(date: entryDate, snapshot: snapshot))
        }
        // 마지막 entry 직후 reload — 다음 rotation cycle을 위해 fresh fetch.
        let reloadAt = (entries.last?.date ?? now).addingTimeInterval(Self.rotationInterval)
        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }

    /// Round-robin 회전 간격(초). 60초 = 분 단위 갱신과 일치 → 카운트다운/회전이 동시에 부드럽게.
    private static let rotationInterval: TimeInterval = 60
    /// 미리 발급할 entry 한도. 60초 × 30 = 30분 window. WidgetKit 60-entry 한계 + lock screen budget 보수.
    private static let maxEntries = 30

    // MARK: - 데이터

    /// `now` 기준 relevant한 NTD ItemSnapshot 목록 (정렬됨). 없으면 빈 배열.
    /// 정렬: priority(high→none) → sortAnchor(종료 가까운 순) — 홈 위젯과 동일 규칙.
    /// Round-robin 회전 시 이 순서대로 cycle.
    /// internal — circular lock widget(MyDaysNTDLockCircleWidget)이 같은 fetch 로직 재사용.
    static func fetchRelevantNTDSnapshots(now: Date) -> [ItemSnapshot] {
        let context = PersistenceController.shared.viewContext
        // Multi-process Core Data — main app save가 widget process 캐시에 반영되도록 강제.
        context.refreshAllObjects()
        let request: NSFetchRequest<Item> = Item.fetchRequest()
        request.predicate = NSPredicate(format: "status == 0 AND kind == 1")
        let items = (try? context.fetch(request)) ?? []
        let today: Date = .todayCalendarAnchor

        let snaps: [ItemSnapshot] = items.compactMap { item in
            // 오늘 포기 occurrence가 있는 NTD는 제외.
            if let rec = item.routineRecord(on: today), rec.failed { return nil }
            guard let occ = item.ntdRelevantOccurrenceDate(at: now),
                  let state = item.ntdState(on: occ, now: now), state != .ended,
                  let start = item.ntdStartInstant(on: occ) else { return nil }
            // 미래 occurrence(다음 일 이후)는 제외 — "오늘 일정" 범위.
            let occDay = Calendar.gmt.startOfDay(for: occ)
            if occDay > today { return nil }
            let end = item.ntdEndInstant(on: occ)
            let display: ItemSnapshot.DisplayState
            switch state {
            case .scheduled:  display = .scheduled
            case .inProgress: display = .inProgress
            case .ended:      return nil
            }
            return ItemSnapshot(
                kind: .notTodo,
                isRoutine: item.recurrenceRule != nil,
                title: item.title ?? "",
                priority: item.itemPriority,
                state: display,
                startInstant: start,
                endInstant: end
            )
        }

        return snaps.sorted { a, b in
            if a.priorityOrder != b.priorityOrder { return a.priorityOrder < b.priorityOrder }
            return a.sortAnchor < b.sortAnchor
        }
    }
}

// MARK: - View

struct MyDaysNTDLockWidgetEntryView: View {

    let entry: NTDLockEntry

    var body: some View {
        Group {
            if let snap = entry.snapshot {
                content(for: snap)
            } else {
                emptyContent
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// 3줄 layout (캘린더 위젯 스타일):
    ///   - 1행: 아이콘 + NTD 제목 (작은 폰트)
    ///   - 2행: 카운트다운 (큰 폰트, widgetAccentable로 tint 강조 — main glanceable signal)
    ///   - 3행: 상태 라벨 "남음/진행/대기" (작은 폰트)
    /// 잠금화면 vibrancy 환경: widgetAccentable() 영역만 watch face tint, 나머지는 secondary 톤.
    @ViewBuilder
    private func content(for snap: ItemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "stopwatch")
                    .imageScale(.small)
                Text(verbatim: snap.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            countdownText(for: snap)
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .widgetAccentable()

            stateLabel(for: snap)
                .font(.caption2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: "stopwatch")
                .imageScale(.small)
            Text("widget.ntd.empty")
                .font(.caption2)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 잠금화면용 카운트다운/경과 텍스트.
    /// `Text(timerInterval:)`은 초 단위로 표시되는데 iOS가 잠금화면에서 초를 "--"로 가려서 가독성 나쁨 →
    /// TimelineView + 1분 갱신으로 직접 포맷. "1일 5시간 30분" 형식, 초 단위 생략.
    /// - scheduled: 시작 instant까지 count down
    /// - inProgress + 종료 있음: 종료 instant까지 count down
    /// - inProgress + 종료 없음 (NTD 한계까지): 시작 instant부터 count up
    @ViewBuilder
    private func countdownText(for snap: ItemSnapshot) -> some View {
        switch snap.state {
        case .scheduled, .inProgress:
            durationTimeline(for: snap)
        case .overdue, .untimed:
            // NTD는 자동 완료라 overdue 도달 X. untimed도 발생 X (NTD는 항상 hasTime).
            EmptyView()
        }
    }

    /// 1분 주기로 갱신되는 duration 텍스트. 잠금화면 widget OS update 주기와 일치.
    @ViewBuilder
    private func durationTimeline(for snap: ItemSnapshot) -> some View {
        let now = Date()
        TimelineView(.periodic(from: now, by: 60)) { context in
            let secs = Self.remainingSeconds(for: snap, now: context.date)
            Text(verbatim: Self.formatDHM(seconds: secs))
        }
    }

    /// snap 상태별 표시할 초.
    /// - scheduled: 시작까지 남은 초
    /// - inProgress + end: 종료까지 남은 초
    /// - inProgress + no end: 시작부터 경과 초
    /// internal — circular widget 재사용.
    static func remainingSeconds(for snap: ItemSnapshot, now: Date) -> Int {
        switch snap.state {
        case .scheduled:
            return max(0, Int(snap.startInstant.timeIntervalSince(now)))
        case .inProgress:
            if let end = snap.endInstant {
                return max(0, Int(end.timeIntervalSince(now)))
            }
            return max(0, Int(now.timeIntervalSince(snap.startInstant)))
        case .overdue, .untimed:
            return 0
        }
    }

    /// "1일 5시간 30분" 형식. 0인 leading/trailing unit은 생략. 1분 미만은 "1분"으로 floor (초 노출 회피).
    /// 단위 텍스트는 기존 ntd.countdown.{d,h,m}_format 재사용 — "1d 5h 30m" / "1일 5시간 30분" 자동 로컬라이즈.
    /// internal — circular lock widget이 동일 포맷 사용.
    static func formatDHM(seconds: Int) -> String {
        let s = max(0, seconds)
        // < 1분 → "1분"으로 표시 (실제 초는 가리고, 임박했음만 전달)
        if s < 60 {
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.countdown.m_format", comment: ""), 1
            )
        }
        let totalMin = s / 60
        let days = totalMin / (24 * 60)
        let hours = (totalMin % (24 * 60)) / 60
        let minutes = totalMin % 60

        var parts: [String] = []
        if days > 0 {
            parts.append(String.localizedStringWithFormat(
                NSLocalizedString("ntd.countdown.d_format", comment: ""), days))
        }
        if hours > 0 {
            parts.append(String.localizedStringWithFormat(
                NSLocalizedString("ntd.countdown.h_format", comment: ""), hours))
        }
        if minutes > 0 {
            parts.append(String.localizedStringWithFormat(
                NSLocalizedString("ntd.countdown.m_format", comment: ""), minutes))
        }
        return parts.joined(separator: " ")
    }

    /// 상태 라벨 — circular widget과 동일한 짧은 키 재사용 ("남음/진행/대기").
    /// 잠금화면 위젯 일관성 + 좁은 공간에 적합.
    private func stateLabel(for snap: ItemSnapshot) -> Text {
        switch snap.state {
        case .scheduled:
            return Text("widget.ntd_lock_circle.status.scheduled")
        case .inProgress:
            return snap.endInstant != nil
                ? Text("widget.ntd_lock_circle.status.remaining")
                : Text("widget.ntd_lock_circle.status.elapsed")
        case .overdue:
            return Text("widget.state.overdue")
        case .untimed:
            return Text("widget.state.today")
        }
    }
}

// MARK: - Widget Configuration

struct MyDaysNTDLockWidget: Widget {
    let kind: String = "MyDaysNTDLockWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NTDLockProvider()) { entry in
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
    NTDLockEntry(
        date: .now,
        snapshot: ItemSnapshot(
            kind: .notTodo, isRoutine: false,
            title: "16시간 단식",
            priority: .high, state: .inProgress,
            startInstant: .now.addingTimeInterval(-3600),
            endInstant: .now.addingTimeInterval(5 * 3600 + 23 * 60)
        )
    )
    NTDLockEntry(
        date: .now,
        snapshot: ItemSnapshot(
            kind: .notTodo, isRoutine: true,
            title: "디저트 끊기",
            priority: .medium, state: .scheduled,
            startInstant: .now.addingTimeInterval(2 * 3600),
            endInstant: .now.addingTimeInterval(26 * 3600)
        )
    )
    NTDLockEntry(date: .now, snapshot: nil)
}
