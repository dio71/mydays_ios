import SwiftUI

// MARK: - Todo 미리 완료 사유 입력 시트
//
// 시작 instant 전(미래 일정)인 Todo를 사용자가 체크할 때 사유 입력.
// 구조는 NTDGiveUpSheet와 동일 — chip + 자유 입력, comment String? 반환.
//
// 저장 위치 (호출 측 onConfirm에서):
//   - RoutineCompletion(done=true).comment = 사유 (NTD 포기와 동일 컬럼)
//   - ItemEvent.log(.completed, note: 사유)
//
// preset chip은 NTD 포기와 시각적 일관성을 유지하면서 라벨만 완료 맥락으로 교체.
// 확인 버튼은 완료(중립 액션)이므로 NTD 포기의 destructive 스타일을 쓰지 않음.

struct TodoCompleteSheet: View {

    /// 확정 시 호출. comment 값(nil 또는 사용자 입력/선택).
    let onConfirm: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKey: String?
    @State private var customText: String = ""

    private static let presetReasonKeys: [String] = [
        "todo.complete_sheet.reason.early",
        "todo.complete_sheet.reason.cancelled",
        "todo.complete_sheet.reason.plan_change",
        "todo.complete_sheet.reason.just_done"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("todo.complete_sheet.section.preset") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.presetReasonKeys, id: \.self) { key in
                                reasonChip(catalogKey: key)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section("todo.complete_sheet.section.custom") {
                    TextField(
                        "todo.complete_sheet.input_placeholder",
                        text: $customText,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("todo.complete_sheet.description")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("todo.complete_sheet.title")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") {
                        onConfirm(resolvedComment)
                        dismiss()
                    }
                }
            }
        }
    }

    /// customText 우선, 비어 있으면 선택된 preset의 localized text, 둘 다 없으면 nil.
    private var resolvedComment: String? {
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let key = selectedKey {
            return NSLocalizedString(key, comment: "")
        }
        return nil
    }

    private func reasonChip(catalogKey: String) -> some View {
        let isSelected = selectedKey == catalogKey
        let label = NSLocalizedString(catalogKey, comment: "")
        return Button {
            selectedKey = isSelected ? nil : catalogKey
        } label: {
            Text(verbatim: label)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor : Color.clear)
                )
                .overlay(
                    Capsule().stroke(isSelected ? Color.clear : Color.accentColor, lineWidth: 1)
                )
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    Text("Preview host")
        .sheet(isPresented: .constant(true)) {
            TodoCompleteSheet { comment in
                print("confirmed: \(comment ?? "nil")")
            }
        }
}
