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
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    cell(for: day)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelectDate(day)
                        }
                }
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
        .padding(.vertical, 6)
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

    @ViewBuilder
    private func cell(for date: Date) -> some View {
        let isSelected = Calendar.gmt.isDate(date, inSameDayAs: selectedDate)
        let isToday = Calendar.gmt.isDate(date, inSameDayAs: .todayCalendarAnchor)
        // 배경 원: 선택일은 solid accent, 오늘(미선택)은 반투명 accent. 둘 다면 selection 우선.
        let bgFill: Color? = {
            if isSelected { return Color.accentColor }
            if isToday { return Color.accentColor.opacity(0.5) }
            return nil
        }()
        VStack(spacing: 4) {
            Text(verbatim: Self.weekdayLabel(date))
                .font(.caption2)
                .foregroundStyle(isToday ? Color.accentColor : .secondary)
            Text(verbatim: Self.dayNumber(date))
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : .primary)
                .frame(width: 28, height: 28)
                .background {
                    if let bgFill {
                        Circle().fill(bgFill)
                    }
                }
        }
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
