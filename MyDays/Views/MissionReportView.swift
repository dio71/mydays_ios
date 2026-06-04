import SwiftUI
import CoreData

// MARK: - MissionReportView
//
// 반복 항목(반복 목표 4-type / 반복 Todo) 보고서 화면.
// 진입점: AddItemView 상단 chart 버튼 → sheet 안에 노출.
// 1회성 항목은 진입점 자체가 hide → 이 화면 진입 자체가 없음 (정책 보호용 빈 상태만 유지).
//
// 구조:
// - 섹션 1: 헤더 — 항목 아이콘 + 제목 + [요약][로그] 탭 picker
// - 요약 탭:
//   - 섹션 2: days-since 헤더 + 6-카드 통계 grid
//   - 섹션 3: 이번주 (MonthGridView .week 모드, 한 주 뒤로만 swipe)
//   - 섹션 4: 올해 (YearGridView 축소 cell, swipe 가능)
// - 로그 탭:
//   - 섹션 2: 월간 grid (MonthGridView .month 모드, swipe 가능)
//   - 섹션 3+: 기존 ActivityHistoryView 의 월별 시계열 list (재사용 검토)
//
// 통계:
// - 분모 = rule.occurs(...) 시작일~오늘 (양 끝 포함).
// - 이번달/올해 카운트는 `rc.date` (occurrence 시작일자) 기준.
// - 활동·집중도 동일 (target 도달 = done=true 1회).

struct MissionReportView: View {

    @ObservedObject var item: Item
    let showsCloseButton: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: ReportTab = .summary
    /// 로그 탭의 month grid 표시 일자 anchor (UTC).
    @State private var logMonthDate: Date = .todayCalendarAnchor
    /// month grid 슬라이드 transition 방향.
    @State private var logMonthForward: Bool = false

    enum ReportTab: String, CaseIterable, Identifiable {
        case summary, log
        var id: String { rawValue }
        var labelKey: LocalizedStringKey {
            switch self {
            case .summary: return "report.tab.summary"
            case .log: return "report.tab.log"
            }
        }
    }

    var body: some View {
        Group {
            if item.recurrenceRule == nil {
                emptyOneOffPlaceholder
            } else {
                List {
                    headerSection
                    if selectedTab == .summary {
                        summarySections
                    } else {
                        logSections
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(Text(verbatim: item.title ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }

    // MARK: - 헤더

    @ViewBuilder
    private var headerSection: some View {
        Section {
            Picker(selection: $selectedTab) {
                ForEach(ReportTab.allCases) { tab in
                    Text(tab.labelKey).tag(tab)
                }
            } label: {
                Text("report.tab.summary")
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - 요약 탭

    @ViewBuilder
    private var summarySections: some View {
        statsSection
        thisWeekSection
        thisYearSection
    }

    // MARK: - 올해 (year grid — 정적)

    /// 올해 grid — YearGridView 재활용. 정적 (swipe 없음, 올해 고정).
    @ViewBuilder
    private var thisYearSection: some View {
        let currentYear = Calendar.gmt.component(.year, from: .todayCalendarAnchor)
        Section {
            YearGridView(
                item: item,
                year: currentYear,
                forward: false,
                onShiftYear: { _ in },
                swipeEnabled: false,
                compactHeight: true
            )
            // YearGridView 내부 padding(.vertical, 3)이 양쪽에 3pt씩 추가됨.
            // listRow 위/아래로 9pt씩 — 시각적으로 cell 위/아래 약 12pt씩 균등.
            .listRowInsets(EdgeInsets(top: 9, leading: 0, bottom: 9, trailing: 0))
        } header: {
            HStack {
                Text("report.section.this_year")
                Spacer()
                Text(verbatim: yearLabel(currentYear))
            }
        }
    }

    /// 연도 라벨 — 한글 "2026년" / 영문 "2026".
    private func yearLabel(_ year: Int) -> String {
        if Locale.preferredLanguages.first?.hasPrefix("ko") == true {
            return "\(year)년"
        }
        return "\(year)"
    }

    // MARK: - 이번주 (week grid — 정적)

    /// 이번주 grid — MonthGridView .week 모드 재활용. 정적 (swipe 없음, 이번주 고정).
    /// pickedItemID = item.id로 해당 항목만 dot/ring 노출. divider 숨김.
    @ViewBuilder
    private var thisWeekSection: some View {
        Section {
            MonthGridView(
                selectedDate: .todayCalendarAnchor,
                forward: false,
                onSelectDate: { _ in },
                onShift: { _ in },
                pickedItemID: item.id,
                displayMode: .week,
                showsSelection: false,
                showsDividers: false,
                swipeEnabled: false
            )
            // 좌우/상하 row 기본 inset 축소. bottom 0 — MonthGridView 내부 padding만 유지.
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0))
        } header: {
            Text("report.section.this_week")
        }
    }

    /// 6 카드 통계 grid + days-since 헤더. reportStats를 1회 계산해 카드에 분배.
    @ViewBuilder
    private var statsSection: some View {
        let stats = item.reportStats()
        Section {
            // 3×2 grid — aspectRatio 1:1로 정사각형 카드. 가로 spacing 8.
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                spacing: 8
            ) {
                statCard(
                    icon: "flame",
                    value: "\(stats.currentStreak)",
                    label: "report.stat.current_streak"
                )
                statCard(
                    icon: "trophy",
                    value: "\(stats.maxStreak)",
                    label: "report.stat.max_streak"
                )
                statCard(
                    icon: "checkmark.seal",
                    value: "\(stats.totalCompletions)",
                    label: "report.stat.total"
                )
                statCard(
                    icon: "calendar",
                    value: "\(stats.monthCompletions)",
                    label: "report.stat.this_month"
                )
                statCard(
                    icon: "laurel.leading.laurel.trailing",
                    value: "\(stats.yearCompletions)",
                    label: "report.stat.this_year"
                )
                statCard(
                    icon: "chart.pie",
                    value: completionRateValue(stats.completionRate),
                    label: "report.stat.completion_rate"
                )
            }
            // 카드 자체가 색 박스라 외부 section bg는 투명. 카드 사이 list separator도 hide.
            // listRowInsets=0 — row 기본 좌우 inset(~20pt) 제거해 grid가 row 폭 전체 차지.
            // → 카드 좌우 끝이 다른 섹션 row 배경(rounded card)의 좌우 끝과 align.
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
        } header: {
            Text(daysSinceText(stats.daysSinceStart))
        }
    }

    /// 단일 통계 카드 — accent filled circle 안에 흰 SF Symbol + 수치 + 설명.
    /// 아이콘 48×48, 수치 폰트 largeTitle, 박스 cornerRadius 18.
    /// `valueSuffix`가 있으면 value 아래 줄에 작은 폰트로 단위(% 등) 노출 — 달성률 표시용.
    @ViewBuilder
    private func statCard(
        icon: String,
        value: String,
        valueSuffix: String? = nil,
        label: LocalizedStringKey
    ) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 8) {
                ZStack {
                    Circle().fill(Color.accentColor)
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: value)
                        .font(.largeTitle.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if let suffix = valueSuffix {
                        Text(verbatim: suffix)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }

    /// 달성률 수치 (단위 % 제외) — statCard의 value 자리.
    /// 10% 미만 양수는 소수 1자리(`7.5`), 10% 이상 또는 0은 정수(`75`).
    private func completionRateValue(_ rate: Double) -> String {
        let pct = rate * 100
        if pct < 10 && pct > 0 {
            return String(format: "%.1f", pct)
        }
        return "\(Int(pct.rounded()))"
    }

    /// "38일 전에 시작" / "오늘 시작" — 한/영 자동 분기.
    private func daysSinceText(_ days: Int) -> String {
        if days <= 0 {
            return String(localized: "report.days_since.today")
        }
        let format = String(localized: "report.days_since.format")
        return String.localizedStringWithFormat(format, days)
    }

    // MARK: - 로그 탭

    @ViewBuilder
    private var logSections: some View {
        logMonthSection
        logRecordsSection
    }

    /// 로그 탭 — 월간 grid section (swipe로 ±1개월 navigate 가능).
    /// fixedSixRows=true — 4/5/6주짜리 월 전환 시 grid 높이 일정 유지 + 슬라이드 transition 정확.
    @ViewBuilder
    private var logMonthSection: some View {
        Section {
            MonthGridView(
                selectedDate: logMonthDate,
                forward: logMonthForward,
                onSelectDate: { _ in /* 보고서는 read-only */ },
                onShift: handleLogMonthShift,
                pickedItemID: item.id,
                fixedSixRows: true,
                showsSelection: false,
                showsDividers: false,
                useFadeTransition: true
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        } header: {
            Text(verbatim: monthYearLabel(logMonthDate))
        }
    }

    /// 월간 grid swipe shift — ±1개월. 방향 반전 시 forward 먼저 갱신 + date는 다음 run loop.
    private func handleLogMonthShift(_ delta: Int) {
        guard let next = Calendar.gmt.date(byAdding: .month, value: delta, to: logMonthDate) else { return }
        let newForward = delta > 0
        if newForward != logMonthForward {
            logMonthForward = newForward
            DispatchQueue.main.async {
                logMonthDate = next
            }
        } else {
            logMonthDate = next
        }
    }

    /// "2026년 6월" / "June 2026" — month grid 헤더용.
    private func monthYearLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f.string(from: date)
    }

    /// 활동 기록 list — 현재 month grid에서 표시 중인 (year, month) RC만 노출.
    /// 섹션 타이틀 "활동 기록" 고정. `rc.date` (occurrence 시작일자) 기준으로 같은 달 매칭 — 반복 항목 일관 처리.
    @ViewBuilder
    private var logRecordsSection: some View {
        let records = recordsForMonth(logMonthDate)
        Section("report.log.title") {
            if records.isEmpty {
                Text("report.log.empty")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ForEach(records, id: \.objectID) { rc in
                    recordRow(rc)
                }
            }
        }
    }

    /// 표시 일자(`monthAnchor`)와 같은 (year, month) 인 RC만 필터.
    /// `rc.date` (UTC occurrence 시작일자) 기준 — occurrence 시점이 그 달인지로 일관 매칭.
    /// `routineHistoryRecords`가 이미 completedAt desc 정렬이라 결과도 자동 desc.
    private func recordsForMonth(_ monthAnchor: Date) -> [RoutineCompletion] {
        let utc = Calendar.gmt
        let target = utc.dateComponents([.year, .month], from: monthAnchor)
        return item.routineHistoryRecords.filter { rc in
            guard let occ = rc.date else { return false }
            let comps = utc.dateComponents([.year, .month], from: occ)
            return comps.year == target.year && comps.month == target.month
        }
    }

    /// 단일 RC row — 상태 icon + 일자/시각 + (활동/집중) 진행도 또는 (그 외) 코멘트.
    /// 반복 항목이라 occurrence chip 노출 — rc.date가 occurrence 시작일.
    @ViewBuilder
    private func recordRow(_ rc: RoutineCompletion) -> some View {
        let isActivity = rc.item?.itemKind == .activity
        let valueRecorded = Int(rc.valueRecorded?.doubleValue ?? 0)
        let target: Int = {
            if let snap = rc.targetSnapshot?.doubleValue, snap > 0 { return Int(snap) }
            return rc.item?.activityTargetValueInt ?? 0
        }()
        let isActivityProgress = isActivity && !rc.done && !rc.failed && valueRecorded > 0
        VStack(alignment: .leading, spacing: 4) {
            // occurrence chip — rc.date(UTC anchor) 기준.
            if let occDate = rc.date {
                HStack {
                    occurrenceChip(occDate)
                    Spacer(minLength: 0)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: recordIconName(rc: rc, isActivityProgress: isActivityProgress))
                    .foregroundStyle(recordIconColor(rc: rc, isActivityProgress: isActivityProgress))
                Text(verbatim: recordDateLabel(for: rc))
                    .font(.callout)
                    .foregroundStyle(.primary)
                if let timeText = recordTimeLabel(for: rc), !timeText.isEmpty {
                    Text(verbatim: timeText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if isActivity, target > 0 {
                    Text(verbatim: "\(valueRecorded)/\(target)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(rc.done ? Color.accentColor : .secondary)
                } else if let comment = rc.comment, !comment.isEmpty {
                    Text(verbatim: comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func recordIconName(rc: RoutineCompletion, isActivityProgress: Bool) -> String {
        if rc.done { return "checkmark.circle.fill" }
        if rc.failed { return "xmark.circle.fill" }
        if isActivityProgress { return "circle.bottomhalf.filled" }
        return "circle"
    }

    private func recordIconColor(rc: RoutineCompletion, isActivityProgress: Bool) -> Color {
        if rc.done { return Color.accentColor }
        if isActivityProgress { return Color.accentColor }
        return Color.secondary
    }

    /// 표시 일자 — completedAt(instant local 기준) 우선, 없으면 rc.date(UTC anchor) fallback.
    private func recordDateLabel(for rc: RoutineCompletion) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        if let inst = rc.completedAt {
            f.setLocalizedDateFormatFromTemplate("MMMd")
            let day = f.string(from: inst)
            let wf = DateFormatter()
            wf.locale = Locale.current
            wf.setLocalizedDateFormatFromTemplate("EEE")
            return "\(day) (\(wf.string(from: inst)))"
        }
        if let day = rc.date {
            f.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            f.setLocalizedDateFormatFromTemplate("MMMdEEE")
            return f.string(from: day)
        }
        return ""
    }

    private func recordTimeLabel(for rc: RoutineCompletion) -> String? {
        guard let inst = rc.completedAt else { return nil }
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jm")
        return f.string(from: inst)
    }

    /// occurrence 시작일자 chip — ActivityHistoryView와 같은 시각.
    @ViewBuilder
    private func occurrenceChip(_ occDate: Date) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "calendar")
                .font(.system(size: 9))
            Text(verbatim: occurrenceChipLabel(occDate))
                .font(.system(size: 11).monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
    }

    private func occurrenceChipLabel(_ date: Date) -> String {
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        let dateF = DateFormatter()
        dateF.locale = Locale.current
        dateF.timeZone = utc
        dateF.setLocalizedDateFormatFromTemplate("Md")
        let weekdayF = DateFormatter()
        weekdayF.locale = Locale.current
        weekdayF.timeZone = utc
        weekdayF.setLocalizedDateFormatFromTemplate("EEE")
        return "\(dateF.string(from: date)) (\(weekdayF.string(from: date)))"
    }

    // MARK: - 1회성 fallback

    /// 진입 자체를 막아야 하지만 dev/실수 호출 대비 placeholder. 실 운영에선 노출 X.
    @ViewBuilder
    private var emptyOneOffPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
            Text("report.empty.one_off")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
