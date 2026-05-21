import SwiftUI

struct DatePickerSheet: View {

    let initialDate: Date
    let onSelect: (Date) -> Void
    let onClear: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(initialDate: Date, onSelect: @escaping (Date) -> Void, onClear: (() -> Void)? = nil) {
        self.initialDate = initialDate
        self.onSelect = onSelect
        self.onClear = onClear
        self._date = State(initialValue: initialDate)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                    .padding(.horizontal)

                if onClear != nil {
                    Button(role: .destructive) {
                        onClear?()
                        dismiss()
                    } label: {
                        Text("날짜 없음으로 설정")
                    }
                }

                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSelect(date)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    Text("Preview host")
        .sheet(isPresented: .constant(true)) {
            DatePickerSheet(initialDate: Date(), onSelect: { _ in }, onClear: {})
        }
}
