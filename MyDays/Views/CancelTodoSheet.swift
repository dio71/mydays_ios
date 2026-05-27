import SwiftUI

// MARK: - Todo 취소 사유 입력 시트
//
// 사용자가 Todo(또는 routine occurrence)를 명시적으로 취소할 때 사용.
// NTDGiveUpSheet/TodoCompleteSheet와 동일 구조 — chip + 자유 입력, comment String? 반환.
//
// 저장 위치 (호출 측 onConfirm에서):
//   - RoutineCompletion(failed=true).comment = 사유 (NTD 포기와 동일 컬럼)
//   - 1회성 Todo: Item.status = .failed + completedAt + cancelAllNotifications
//   - ItemEvent.log(.failed, note: 사유)
//
// NTD 포기는 "의지 실패", Todo 취소는 "의도 변경" — 데이터적으로는 같은 .failed, UI 라벨만 분기.
// 확인 버튼은 destructive (사용자가 일정을 끝내는 액션).

struct CancelTodoSheet: View {

    /// 시트 상단 설명 문구 — 호출 측에서 occurrence 상태 등에 따라 생성. nil이면 description 숨김.
    var descriptionText: String? = nil

    /// 확정 시 호출. comment 값(nil 또는 사용자 입력/선택).
    let onConfirm: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKey: String?
    @State private var customText: String = ""

    private static let presetReasonKeys: [String] = [
        "todo.cancel_sheet.reason.time_lack",
        "todo.cancel_sheet.reason.cancelled",
        "todo.cancel_sheet.reason.plan_change",
        "todo.cancel_sheet.reason.skipped"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("todo.cancel_sheet.section.preset") {
                    // 가변 폭 chip group — 가로 스크롤 대신 wrap.
                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(Self.presetReasonKeys, id: \.self) { key in
                            reasonChip(catalogKey: key)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section("todo.cancel_sheet.section.custom") {
                    TextField(
                        "todo.cancel_sheet.input_placeholder",
                        text: $customText,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // descriptionText 명시되면 그대로, 아니면 default 안내 문구.
                Group {
                    if let desc = descriptionText, !desc.isEmpty {
                        Text(verbatim: desc)
                    } else {
                        Text("todo.cancel_sheet.description")
                    }
                }
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("todo.cancel_sheet.title")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
            .presentationBackground(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("todo.cancel.confirm", role: .destructive) {
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
            CancelTodoSheet { comment in
                print("cancelled: \(comment ?? "nil")")
            }
        }
}
