import SwiftUI

struct DatePickerSheet: View {

    let initialDate: Date
    let initialTimeOfDay: TimeOfDay
    let onSelect: (Date, TimeOfDay) -> Void
    let onClear: (() -> Void)?
    /// 시간대(오전/오후/저녁) chip 노출 여부.
    /// NTD에선 시작 시각을 hour 단위로 명시하므로 시간대 chip 불필요 → false로 호출.
    let showsTimeOfDay: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var timeOfDay: TimeOfDay
    /// "지우기" 탭으로 닫힌 경우. onDisappear에서 onSelect 재호출 방지.
    @State private var didClear = false

    init(
        initialDate: Date,
        initialTimeOfDay: TimeOfDay = .none,
        showsTimeOfDay: Bool = true,
        onSelect: @escaping (Date, TimeOfDay) -> Void,
        onClear: (() -> Void)? = nil
    ) {
        self.initialDate = initialDate
        self.initialTimeOfDay = initialTimeOfDay
        self.showsTimeOfDay = showsTimeOfDay
        self.onSelect = onSelect
        self.onClear = onClear
        // 외부에서 넘어온 initialDate는 UTC anchor된 calendar date.
        // DatePicker는 local timezone 기준으로 표시하므로, 같은 (y,m,d)의 local 자정 instant로 변환해
        // UI에 의도한 날짜가 정확히 표시되게 한다.
        self._date = State(initialValue: initialDate.localCalendarSameDay)
        self._timeOfDay = State(initialValue: initialTimeOfDay)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    // V/배경 탭 모두 onDisappear에서 selection 적용 — 사용자 선택을 입력 폼에 자동 반영.
                    // DB 저장은 form의 save button에서만.
                    Spacer()
                    headerButton(systemImage: "checkmark") { dismiss() }
                }
                .padding(.horizontal)
                .padding(.top, 20)

                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(.horizontal)

                HStack(spacing: 6) {
                    if showsTimeOfDay {
                        timeChip(.morning)
                        timeChip(.afternoon)
                        timeChip(.evening)
                        timeChip(.none)
                    }
                    Spacer()
                    if onClear != nil {
                        Button(role: .destructive) {
                            didClear = true
                            onClear?()
                            dismiss()
                        } label: {
                            Text("date_picker.clear")
                                .font(.subheadline)
                        }
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.height(480)])
        .presentationDragIndicator(.hidden)
        // 어떤 경로로 닫혀도 (X/V/배경 탭) 선택값을 자동 적용.
        // "지우기"는 별도 처리되었으므로 didClear flag로 제외.
        .onDisappear {
            if !didClear {
                onSelect(date.calendarDateAnchor, timeOfDay)
            }
        }
        .appTint()
    }

    private func headerButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color(.systemGray5)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func timeChip(_ tod: TimeOfDay) -> some View {
        let active = timeOfDay == tod
        return Button {
            timeOfDay = tod
        } label: {
            Text(tod.displayName)
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(active ? Color.accentColor : Color.clear)
                )
                .overlay(
                    Capsule().stroke(active ? Color.clear : Color.accentColor, lineWidth: 1)
                )
                .foregroundStyle(active ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    Text("Preview host")
        .sheet(isPresented: .constant(true)) {
            DatePickerSheet(initialDate: Date(), onSelect: { _, _ in }, onClear: {})
        }
}
