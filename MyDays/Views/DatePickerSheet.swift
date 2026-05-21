import SwiftUI

struct DatePickerSheet: View {

    let initialDate: Date
    let initialTimeOfDay: TimeOfDay
    let onSelect: (Date, TimeOfDay) -> Void
    let onClear: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var timeOfDay: TimeOfDay

    init(
        initialDate: Date,
        initialTimeOfDay: TimeOfDay = .none,
        onSelect: @escaping (Date, TimeOfDay) -> Void,
        onClear: (() -> Void)? = nil
    ) {
        self.initialDate = initialDate
        self.initialTimeOfDay = initialTimeOfDay
        self.onSelect = onSelect
        self.onClear = onClear
        self._date = State(initialValue: initialDate)
        self._timeOfDay = State(initialValue: initialTimeOfDay)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    headerButton(systemImage: "xmark") {
                        dismiss()
                    }
                    Spacer()
                    headerButton(systemImage: "checkmark") {
                        onSelect(date, timeOfDay)
                        dismiss()
                    }
                }
                .padding(.horizontal)
                .padding(.top, 20)

                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(.horizontal)

                HStack(spacing: 6) {
                    timeChip(.morning)
                    timeChip(.afternoon)
                    timeChip(.evening)
                    timeChip(.none)
                    Spacer()
                    if onClear != nil {
                        Button(role: .destructive) {
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
