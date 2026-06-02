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
    /// preset catalog key 또는 user reason raw 텍스트. nil=미선택.
    @State private var selectedKey: String?
    @State private var customText: String = ""
    /// 사용자 추가 사유. UnitSeparator(\u{1F})로 join.
    @AppStorage("user_reasons.todo_cancel") private var userReasonsRaw: String = ""

    private static let presetReasonKeys: [String] = [
        "todo.cancel_sheet.reason.time_lack",
        "todo.cancel_sheet.reason.cancelled",
        "todo.cancel_sheet.reason.plan_change",
        "todo.cancel_sheet.reason.skipped"
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
                Section("todo.cancel_sheet.section.preset") {
                    // 가변 폭 chip group — 가로 스크롤 대신 wrap. preset + user reasons 통합.
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
                Section("todo.cancel_sheet.section.custom") {
                    TextField(
                        "todo.cancel_sheet.input_placeholder",
                        text: $customText,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    addReasonButton
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
                        .tint(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("todo.cancel.confirm", role: .destructive) {
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
            CancelTodoSheet { comment in
                print("cancelled: \(comment ?? "nil")")
            }
        }
}
