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
    /// preset catalog key 또는 user reason raw 텍스트. nil=미선택.
    @State private var selectedKey: String?
    @State private var customText: String = ""
    /// 사용자 추가 사유. UnitSeparator(\u{1F})로 join.
    @AppStorage("user_reasons.todo_complete") private var userReasonsRaw: String = ""

    private static let presetReasonKeys: [String] = [
        "todo.complete_sheet.reason.early",
        "todo.complete_sheet.reason.cancelled",
        "todo.complete_sheet.reason.plan_change",
        "todo.complete_sheet.reason.just_done"
    ]

    private var userReasons: [String] {
        userReasonsRaw.split(separator: "\u{1F}", omittingEmptySubsequences: true).map(String.init)
    }

    private func addUserReason() {
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = userReasons
        guard !list.contains(trimmed) else {
            selectedKey = trimmed
            customText = ""
            return
        }
        list.append(trimmed)
        userReasonsRaw = list.joined(separator: "\u{1F}")
        selectedKey = trimmed
        customText = ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("todo.complete_sheet.section.preset") {
                    // 가변 폭 chip group — preset + user reasons 통합.
                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(Self.presetReasonKeys, id: \.self) { key in
                            reasonChip(identifier: key, label: NSLocalizedString(key, comment: ""))
                        }
                        ForEach(userReasons, id: \.self) { text in
                            reasonChip(identifier: text, label: text)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section("todo.complete_sheet.section.custom") {
                    TextField(
                        "todo.complete_sheet.input_placeholder",
                        text: $customText,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    addReasonButton
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
            .presentationBackground(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") { dismiss() }
                        .tint(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") {
                        onConfirm(resolvedComment)
                        dismiss()
                    }
                }
            }
        }
        .appTint()
    }

    /// customText 우선, 비어 있으면 선택된 chip 텍스트(preset이면 localized, user면 raw), 둘 다 없으면 nil.
    private var resolvedComment: String? {
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let key = selectedKey {
            if Self.presetReasonKeys.contains(key) {
                return NSLocalizedString(key, comment: "")
            }
            return key
        }
        return nil
    }

    /// "선택 항목에 추가" 버튼 — chip outline 스타일.
    @ViewBuilder
    private var addReasonButton: some View {
        let isEnabled = !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack {
            Button {
                addUserReason()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("reason.add_to_options")
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(
                    Capsule().stroke(Color.accentColor, lineWidth: 1)
                )
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.4)
            .allowsHitTesting(isEnabled)
            Spacer()
        }
    }

    private func reasonChip(identifier: String, label: String) -> some View {
        let isSelected = selectedKey == identifier
        return Button {
            selectedKey = isSelected ? nil : identifier
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
