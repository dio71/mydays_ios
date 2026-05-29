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
        // Tiered granularity — 다음 transition까지 거리에 따라 step 동적 변경:
        //   - > 3h: 30분 step
        //   - 3h ~ 1h: 10분 step
        //   - 1h ~ 20분: 5분 step
        //   - < 20분: 1분 step
        //   - transition 없음 (duration 미설정 / 빈 상태): 1h step
        // 멀리 있는 시점은 30min/10min 정밀도면 충분, 가까울수록 fine-grained.
        // transition 시점(시작/종료)은 정확히 entry로 포함 (state flip).
        // horizon: 6시간 — 그 이상은 reload에 위임.
        let activeSnaps = Self.fetchRelevantNTDSnapshots(now: now)
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
        let entries: [NTDLockEntry] = sortedDates.enumerated().map { i, entryDate in
            let snaps = Self.fetchRelevantNTDSnapshots(now: entryDate)
            let snapshot: ItemSnapshot? = snaps.isEmpty ? nil : snaps[i % snaps.count]
            return NTDLockEntry(date: entryDate, snapshot: snapshot)
        }
        let reloadAt = (entries.last?.date ?? now).addingTimeInterval(60)
        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }

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
                endInstant: end,
                categoryIconName: item.category?.iconName,
                categoryColorHex: item.category?.colorHex
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
    ///   - 2행: 카운트다운(큰 폰트, widgetAccentable) + 상태 라벨(작은 폰트, trailing)
    ///   - 3행: 직선 progress bar — inProgress일 때만, 대기는 invisible (layout 유지)
    /// 잠금화면 vibrancy 환경: widgetAccentable() 영역만 watch face tint, 나머지는 secondary 톤.
    @ViewBuilder
    private func content(for snap: ItemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                // 카테고리 설정 시 카테고리 아이콘, 미설정 시 clock fallback.
                // 잠금화면은 monochrome — 색은 시스템 tint에 위임 (widgetAccentable 영역 외 secondary).
                Image(systemName: snap.categoryIconName ?? "clock")
                    .imageScale(.small)
                Text(verbatim: snap.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // 홈 위젯과 같은 패턴 — Spacer로 trailing 정렬, state(caption2 secondary) → countdown(semibold) 순.
            // Text(date, style: .relative)는 "1시간 23분 뒤" 같은 긴 텍스트가 될 수 있어 .footnote + scaleFactor로 lock screen 좁은 폭에 맞춤.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Spacer(minLength: 0)
                stateLabel(for: snap)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                countdownText(for: snap)
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .widgetAccentable()
                    .multilineTextAlignment(.trailing)
                    .minimumScaleFactor(0.7)
            }
            .lineLimit(1)

            progressBar(for: snap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 직선 progress bar — inProgress일 때만 fill, 대기는 invisible (layout 자리는 유지).
    /// entry.date 기준으로 1회 render — Lock Screen TimelineView 갱신 신뢰 X, transition entry로 라이프사이클 처리.
    /// 진행도 계산: MyDaysNTDLockCircleWidgetEntryView.progressValue와 동일 규칙.
    @ViewBuilder
    private func progressBar(for snap: ItemSnapshot) -> some View {
        GeometryReader { proxy in
            let progress: CGFloat = snap.state == .inProgress
                ? CGFloat(MyDaysNTDLockCircleWidgetEntryView.progressValue(for: snap, now: entry.date))
                : 0
            ZStack(alignment: .leading) {
                // 배경 — secondary 흐림.
                Capsule()
                    .fill(.secondary)
                    .opacity(0.3)
                // 진행 fill — widgetAccentable tint.
                if progress > 0 {
                    Capsule()
                        .frame(width: proxy.size.width * progress)
                        .widgetAccentable()
                }
            }
        }
        .frame(height: 3)
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: "clock")
                .imageScale(.small)
            Text("widget.ntd.empty")
                .font(.caption2)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 잠금화면용 카운트다운/경과 텍스트 — 단위 명시 포맷 (예: "20분" / "16시간 30분" / "5일 3시간").
    /// entry.date 기준 미리 계산. Provider가 분 granularity 별 entry 발급해 iOS가 entry swap으로 갱신.
    /// - scheduled: 시작 instant - entry.date 남은 시간
    /// - inProgress + 종료 있음: 종료 instant - entry.date 남은 시간
    /// - inProgress + 종료 없음 (NTD 한계까지): entry.date - 시작 instant 경과 시간
    @ViewBuilder
    private func countdownText(for snap: ItemSnapshot) -> some View {
        Text(verbatim: Self.formatDuration(for: snap, now: entry.date))
    }

    /// 단위 명시 duration 포맷. ntd.countdown.* localized 키 재사용.
    /// - < 1분: "1분" (초 노출 회피, 1분 floor)
    /// - < 1시간: "M분"
    /// - 1시간 ~ 3시간: "H시간 M분" / "H시간" (분 정확도 의미 있음, tier 5min step)
    /// - ≥ 3시간 ~ 24시간: "H시간" (분 단위 제거 — tier 10/30min step이라 분 정확도 떨어짐)
    /// - ≥ 24시간 + 시간 있음: "D일 H시간"
    /// - ≥ 24시간 + 시간 0: "D일"
    static func formatDuration(for snap: ItemSnapshot, now: Date) -> String {
        let seconds: Int
        switch snap.state {
        case .scheduled:
            seconds = max(0, Int(snap.startInstant.timeIntervalSince(now)))
        case .inProgress:
            if let end = snap.endInstant {
                seconds = max(0, Int(end.timeIntervalSince(now)))
            } else {
                seconds = max(0, Int(now.timeIntervalSince(snap.startInstant)))
            }
        case .overdue, .untimed:
            return ""
        }
        let totalMin = seconds < 60 ? 1 : seconds / 60
        let days = totalMin / (24 * 60)
        let hours = (totalMin % (24 * 60)) / 60
        let minutes = totalMin % 60

        if days > 0 {
            if hours > 0 {
                return String.localizedStringWithFormat(
                    NSLocalizedString("ntd.countdown.d_h_format", comment: ""), days, hours)
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.countdown.d_format", comment: ""), days)
        }
        if hours > 0 {
            // 3시간 이상이면 분 단위 제거 — tier granularity(>3h: 30min, 3h~1h: 10min)에서 분 정확도가 떨어져
            // 분 표시는 오히려 사용자에게 혼란만 줌. 3시간 미만(5min step 영역)에서만 분 노출.
            if minutes > 0 && hours < 3 {
                return String.localizedStringWithFormat(
                    NSLocalizedString("ntd.countdown.h_m_format", comment: ""), hours, minutes)
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("ntd.countdown.h_format", comment: ""), hours)
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("ntd.countdown.m_format", comment: ""), minutes)
    }


    /// 상태 라벨 — 홈 위젯과 통일 ("시작까지/종료까지/진행 중"). widget.state.* 키 재사용.
    private func stateLabel(for snap: ItemSnapshot) -> Text {
        switch snap.state {
        case .scheduled:
            return Text("widget.state.scheduled")
        case .inProgress:
            return snap.endInstant != nil
                ? Text("widget.state.remaining")
                : Text("widget.state.elapsed")
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
            endInstant: .now.addingTimeInterval(5 * 3600 + 23 * 60),
            categoryIconName: nil, categoryColorHex: nil
        )
    )
    NTDLockEntry(
        date: .now,
        snapshot: ItemSnapshot(
            kind: .notTodo, isRoutine: true,
            title: "디저트 끊기",
            priority: .medium, state: .scheduled,
            startInstant: .now.addingTimeInterval(2 * 3600),
            endInstant: .now.addingTimeInterval(26 * 3600),
            categoryIconName: nil, categoryColorHex: nil
        )
    )
    NTDLockEntry(date: .now, snapshot: nil)
}
