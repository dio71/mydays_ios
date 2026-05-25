import SwiftUI

// MARK: - NTD 시작 시간 입력 시트
//
// 폰의 시간 표시 설정(12h / 24h)에 따라 wheel 구성이 달라진다.
//   - 24h 모드: 1 wheel (0~23시)
//   - 12h 모드: 1 wheel (24 position, 각 cell에 "오전/오후 N시" 같이 표시)
//     · 별도 AM/PM wheel을 두지 않는 이유: SwiftUI Picker는 wheel이 settle된 후에만
//       selection 변경을 알려서, 분리된 AM/PM wheel을 스크롤 도중 동기화할 수 없음.
//       각 cell에 period+hour를 함께 담아 스크롤 시 시각적 변화가 즉시 보이도록 설계.
//
// 12h 모드의 24 position 구조 (0~23 → 표시 시간):
//   pos 0~10  → "오전 1시" ~ "오전 11시"   (24h hour: 1~11)
//   pos 11    → "오전 12시" = 자정         (24h hour: 0)
//   pos 12~22 → "오후 1시" ~ "오후 11시"   (24h hour: 13~23)
//   pos 23    → "오후 12시" = 정오         (24h hour: 12)

struct StartHourPickerSheet: View {

    let initialHour: Int  // 0~23
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    // 24h 모드 전용
    @State private var hour24: Int

    // 12h 모드 전용 — 0~23 position (1~12를 두 번 노출).
    @State private var hourPosition: Int

    init(initialHour: Int, onSelect: @escaping (Int) -> Void) {
        self.initialHour = initialHour
        self.onSelect = onSelect
        self._hour24 = State(initialValue: initialHour)
        self._hourPosition = State(initialValue: Self.hourToPosition(initialHour))
    }

    /// 시스템 시간 표시 설정 (12h or 24h).
    /// "j" template은 사용자 locale의 hour cycle을 반환 — 'a'가 포함되면 12h 모드.
    static var uses24HourTime: Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.current) ?? ""
        return !format.contains("a")
    }

    // MARK: - position ↔ hour 변환
    // 인라인 picker(AddItemView)에서도 재사용하므로 internal 노출.

    static func hourToPosition(_ hour: Int) -> Int {
        if hour == 0  { return 11 }  // 오전 12시 = 자정
        if hour == 12 { return 23 }  // 오후 12시 = 정오
        return hour - 1               // 1~11 → 0~10, 13~23 → 12~22
    }

    static func hour24(forPosition pos: Int) -> Int {
        if pos == 11 { return 0 }
        if pos == 23 { return 12 }
        return pos + 1
    }

    /// 최종 저장할 0~23 hour.
    private var resolvedHour: Int {
        if Self.uses24HourTime { return hour24 }
        return Self.hour24(forPosition: hourPosition)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    // V/배경 탭 모두 onDisappear에서 자동 적용.
                    Spacer()
                    headerButton(systemImage: "checkmark") { dismiss() }
                }
                .padding(.horizontal)
                .padding(.top, 20)

                if Self.uses24HourTime {
                    wheel24
                } else {
                    wheel12
                }

                Spacer()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        // header(~60pt) + wheel(~216pt) + 여백 — wheel 높이에 맞춤.
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.hidden)
        // 어떤 경로로 닫혀도 자동 적용.
        .onDisappear { onSelect(resolvedHour) }
    }

    // MARK: - wheels

    private var wheel24: some View {
        Picker(selection: $hour24) {
            ForEach(0...23, id: \.self) { h in
                Text(verbatim: hour24Label(h))
                    .monospacedDigit()
                    .tag(h)
            }
        } label: { EmptyView() }
        .pickerStyle(.wheel)
        .labelsHidden()
        .padding(.horizontal)
    }

    private var wheel12: some View {
        Picker(selection: $hourPosition) {
            ForEach(0...23, id: \.self) { pos in
                Text(verbatim: Self.cellLabel12(pos: pos))
                    .monospacedDigit()
                    .tag(pos)
            }
        } label: { EmptyView() }
        .pickerStyle(.wheel)
        .labelsHidden()
        .padding(.horizontal)
    }

    // MARK: - labels

    /// 24h 모드 cell — 사용자 locale에 맞춰 "n시" 또는 "n:00".
    /// 1자리 시간은 leading figure space로 padding해 wheel 스크롤 시 위치 흔들림 방지.
    private func hour24Label(_ h: Int) -> String {
        let raw = String.localizedStringWithFormat(
            NSLocalizedString("ntd.start_hour_format", comment: ""),
            h
        )
        return Self.padSingleDigitHour(raw, hour: h)
    }

    /// 12h 모드 cell — locale-aware "오전 11시" / "11 AM" 등.
    /// DateFormatter "j" template은 locale의 hour cycle pattern을 반환 — 12h 모드 locale에선
    /// "a h시" (ko) 또는 "h a" (en) 같이 period 포함 형식이 나옴.
    /// 단자리 시간(1~9)은 leading figure space로 padding해 "오전"/"오후" 위치 고정.
    /// 인라인 picker에서도 재사용하므로 internal.
    static func cellLabel12(pos: Int) -> String {
        let h24 = Self.hour24(forPosition: pos)
        let h12: Int = pos % 12 == 11 ? 12 : (pos % 12) + 1
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("j")
        var comps = DateComponents()
        comps.hour = h24
        comps.minute = 0
        let raw: String
        if let date = Calendar.current.date(from: comps) {
            raw = formatter.string(from: date)
        } else {
            raw = "\(h24)"
        }
        return padSingleDigitHour(raw, hour: h12)
    }

    /// 단자리 시간(1~9)이면 해당 숫자 앞에 figure space(U+2007, digit-width)를 한 칸 삽입.
    /// 두자리(10~12)와 같은 폭이 되어 cell 안에서 텍스트 위치가 고정됨.
    /// U+2007은 비례 폰트에서도 숫자 한 자 폭으로 렌더 → "\u{2007}1" ≈ "11" 너비.
    static func padSingleDigitHour(_ raw: String, hour: Int) -> String {
        guard hour < 10 else { return raw }
        let hourStr = "\(hour)"
        if let range = raw.range(of: hourStr) {
            return raw.replacingCharacters(in: range, with: "\u{2007}\(hourStr)")
        }
        return "\u{2007}\(raw)"
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
            StartHourPickerSheet(initialHour: 15) { _ in }
        }
}
