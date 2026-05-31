import SwiftUI

// MARK: - WeekStripView
//
// TodayView 상단에 표시하는 7-cell 요일 strip.
// - 각 cell: 요일 라벨 (요일/E) + 날짜 숫자
// - 일자 cell 탭 → onSelectDate(date) 콜백 → 부모가 navigateTo로 일자 이동
// - 가로 swipe → onShiftWeek(±7) 콜백 → 부모가 ±7일 shift
// - 주 시작점: `Calendar.current.firstWeekday` (한국=일요일, 유럽=월요일 자동)
// - 날짜 표시·비교는 모두 UTC anchor (CLAUDE.md Timezone 정책 준수). firstWeekday만 local.
//
// Phase 2 (Month grid) / Phase 3 (NTD 히스토리) 에서 같은 cell 패턴 재활용 가능하도록 단순화 유지.

struct WeekStripView: View {

    /// 현재 선택된 일자 (UTC anchor). 강조 표시 + 주 strip 계산 anchor.
    let selectedDate: Date

    /// 직전 navigation 방향 — TodayView의 `lastNavigationForward`를 그대로 전달받음.
    /// true=미래/오른쪽 이동, false=과거/왼쪽 이동. 슬라이드 transition edge 계산용.
    let forward: Bool

    /// 일자 cell 탭 callback — 부모 view에서 navigation direction 결정 후 displayedDate 변경.
    let onSelectDate: (Date) -> Void

    /// 가로 swipe로 ±7일 shift callback (음수=과거, 양수=미래).
    let onShiftWeek: (Int) -> Void

    var body: some View {
        // TodayView 본문과 동일한 transition 패턴: ZStack + .id로 view identity 변경 시 슬라이드.
        // forward=true면 새 view가 오른쪽에서 진입, 이전 view가 왼쪽으로 퇴장. forward=false면 반대.
        let insertionEdge: Edge = forward ? .trailing : .leading
        let removalEdge: Edge = forward ? .leading : .trailing

        ZStack {
            VStack(spacing: 0) {
                // 요일 row.
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        weekdayCell(for: day)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 4)
                // 요일 아래 분리선.
                Divider()
                // 날짜 row — tap 가능.
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        dayCell(for: day)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelectDate(day)
                            }
                    }
                }
                .padding(.vertical, 4)
                // 날짜 아래 분리선.
                Divider()
            }
            .id(weekStart)
            .transition(.asymmetric(
                insertion: .move(edge: insertionEdge),
                removal: .move(edge: removalEdge)
            ))
        }
        .clipped()
        .animation(.easeInOut(duration: 0.22), value: weekStart)
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    let h = value.translation.width
                    let v = value.translation.height
                    guard abs(h) > 60, abs(h) > abs(v) * 2 else { return }
                    // 오른쪽 swipe → 이전 주, 왼쪽 swipe → 다음 주 (본문의 일 단위 swipe 방향과 일치).
                    onShiftWeek(h > 0 ? -7 : 7)
                }
        )
    }

    /// 화면에 표시할 7일 (UTC anchor 배열). selectedDate가 속한 주의 시작일부터 7일.
    private var days: [Date] {
        guard let start = weekStart else { return [] }
        return (0..<7).compactMap {
            Calendar.gmt.date(byAdding: .day, value: $0, to: start)
        }
    }

    /// selectedDate가 속한 주의 첫 일자 (UTC anchor). firstWeekday는 시스템 로케일 기반.
    /// UTC anchor → local 같은 (y,m,d) → 그 주의 시작 → UTC anchor 변환.
    private var weekStart: Date? {
        let localDay = selectedDate.localCalendarSameDay
        guard let interval = Calendar.current.dateInterval(of: .weekOfYear, for: localDay) else {
            return nil
        }
        return interval.start.calendarDateAnchor
    }

    // MARK: - Cell

    /// 요일 라벨 cell (상단 row) — tap 비활성. 오늘 column은 accent 강조.
    @ViewBuilder
    private func weekdayCell(for date: Date) -> some View {
        let isToday = Calendar.gmt.isDate(date, inSameDayAs: .todayCalendarAnchor)
        Text(verbatim: Self.weekdayLabel(date))
            .font(.caption2)
            .foregroundStyle(isToday ? Color.accentColor : .secondary)
    }

    /// 날짜 cell (하단 row) — tap 활성. MonthGridView와 동일 시각 정책:
    /// - Today: 우상단 작은 red dot
    /// - Selected: 가는 accent stroke 1pt
    /// - 숫자 색: today면 accent, 그 외 primary
    @ViewBuilder
    private func dayCell(for date: Date) -> some View {
        let isSelected = Calendar.gmt.isDate(date, inSameDayAs: selectedDate)
        let isToday = Calendar.gmt.isDate(date, inSameDayAs: .todayCalendarAnchor)
        ZStack(alignment: .topTrailing) {
            ZStack {
                Text(verbatim: Self.dayNumber(date))
                    .font(.callout.weight(isToday ? .semibold : .regular))
                    .foregroundStyle(isToday ? Color.accentColor : Color.primary)
                if isSelected {
                    Circle().stroke(Color.accentColor, lineWidth: 1)
                }
            }
            .frame(width: 28, height: 28)

            if isToday {
                Circle()
                    .fill(Color.red)
                    .frame(width: 4, height: 4)
                    .offset(x: 1, y: -1)
            }
        }
        .frame(width: 28, height: 28)
    }

    /// 요일 라벨 — EEE 템플릿. 한국어 "수" / 영어 "Wed" 자동.
    /// 캘린더 날짜는 UTC anchor라 formatter timezone도 UTC 강제.
    private static func weekdayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: date)
    }

    /// 날짜 숫자 — "1" ~ "31".
    private static func dayNumber(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        f.locale = Locale.current
        f.dateFormat = "d"
        return f.string(from: date)
    }
}

#Preview {
    @Previewable @State var selected: Date = .todayCalendarAnchor
    @Previewable @State var forward: Bool = true
    return WeekStripView(
        selectedDate: selected,
        forward: forward,
        onSelectDate: { date in
            forward = date > selected
            selected = date
        },
        onShiftWeek: { delta in
            if let next = Calendar.gmt.date(byAdding: .day, value: delta, to: selected) {
                forward = delta > 0
                selected = next
            }
        }
    )
    .padding()
}
