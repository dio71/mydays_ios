import SwiftUI

// MARK: - NTD 목표 유지 시간 입력 시트
//
// 2-row wheel (일 + 시간)으로 자유 입력. 저장은 총 시간(시) 단위.
//   예) 1일 12시간 = 36시간, 7일 0시간 = 168시간
// "미설정" toggle로 nil(=한계까지) 표시 가능.
//
// 디자인 결정:
// - sheet 열 때 isUnset = false로 강제. 사용자가 row를 탭한 행위 자체가
//   "이번엔 시간을 설정하겠다"는 의도이므로 wheel을 바로 노출하는 게 자연.
//   기존 unset 상태로 되돌리려면 명시적으로 toggle ON.
// - day 0~30, hour 0~23 (실용 상한 ~1개월). 추가 필요 시 day 상한 상향.
// - day=0 && hour=0 조합은 의미 없으므로 V 버튼 disable.

struct DurationPickerSheet: View {

    let initialDurationHour: Int?  // nil = 미설정 (한계까지)
    let onSelect: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isUnset: Bool
    @State private var days: Int
    @State private var hours: Int

    init(initialDurationHour: Int?, onSelect: @escaping (Int?) -> Void) {
        self.initialDurationHour = initialDurationHour
        self.onSelect = onSelect
        // 기존값이 있으면 그 값을 (일, 시)로 분해. 없으면 16시간(대중적 단식)을 default 시작점으로.
        let total = initialDurationHour ?? 16
        self._days = State(initialValue: total / 24)
        self._hours = State(initialValue: total % 24)
        // sheet 열린 순간은 항상 toggle OFF — 시간 설정 의도로 해석.
        self._isUnset = State(initialValue: false)
    }

    private var totalHours: Int { days * 24 + hours }
    private var canConfirm: Bool { isUnset || totalHours > 0 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    // V/배경 탭 모두 onDisappear에서 자동 적용.
                    Spacer()
                    headerButton(systemImage: "checkmark") { dismiss() }
                        .disabled(!canConfirm)
                        .opacity(canConfirm ? 1 : 0.4)
                }
                .padding(.horizontal)
                .padding(.top, 20)

                Toggle(isOn: $isUnset) {
                    Text("ntd.duration.unset")
                        .font(.subheadline)
                }
                .padding(.horizontal)

                // wheel은 toggle OFF일 때만 노출.
                if !isUnset {
                    HStack(spacing: 0) {
                        Picker(selection: $days) {
                            ForEach(0...30, id: \.self) { d in
                                Text(verbatim: dayLabel(d)).tag(d)
                            }
                        } label: { EmptyView() }
                        .pickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)

                        Picker(selection: $hours) {
                            ForEach(0...23, id: \.self) { h in
                                Text(verbatim: hourLabel(h)).tag(h)
                            }
                        } label: { EmptyView() }
                        .pickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal)
                }

                Spacer()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        // header(~60) + toggle(~50) + wheels(~216) + 여백.
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.hidden)
        // 어떤 경로로 닫혀도 자동 적용 (canConfirm 만족 시).
        // isUnset이면 nil, 아니면 totalHours. totalHours==0 (일·시 모두 0) 케이스는 무시.
        .onDisappear {
            if canConfirm {
                onSelect(isUnset ? nil : totalHours)
            }
        }
    }

    private func dayLabel(_ d: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("ntd.duration.day_format", comment: ""),
            d
        )
    }

    private func hourLabel(_ h: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("ntd.duration_format", comment: ""),
            h
        )
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
}

#Preview {
    Text("Preview host")
        .sheet(isPresented: .constant(true)) {
            DurationPickerSheet(initialDurationHour: 36) { _ in }
        }
}
