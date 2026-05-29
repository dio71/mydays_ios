import SwiftUI

// MARK: - NTD 포기 사유 입력 시트
//
// 진행 중인 NTD occurrence를 사용자가 명시적으로 종료할 때 사용.
// preset chip 선택 또는 직접 입력. 둘 다 비우면 사유 없이 포기.
// 우선순위:
//   - customText가 비어 있지 않으면 customText
//   - 그 외 selectedReason chip 라벨 (선택 시)
//   - 둘 다 없으면 nil → comment 저장 안 함
//
// 저장 위치 (호출 측 onConfirm에서):
//   - 1회성 NTD: RoutineCompletion(failed=true).comment + Item.status=failed
//   - 반복 NTD: RoutineCompletion(failed=true).comment (per-occurrence)
//   둘 다 RC.comment로 통일 — 1회성↔반복 전환 시에도 기록 보존.

struct NTDGiveUpSheet: View {

    /// 시트 상단 설명 문구 — 호출 측에서 occurrence 상태(남음/경과 시간)에 따라 생성.
    /// nil이면 description section 숨김 (legacy 호출 호환).
    var descriptionText: String? = nil

    /// 확정 시 호출. comment 값(nil 또는 사용자 입력/선택).
    let onConfirm: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 선택된 preset chip의 catalog key. nil이면 chip 미선택.
    @State private var selectedKey: String?
    @State private var customText: String = ""

    /// preset 사유 chip 목록. (LocalizedStringKey, NSLocalizedString 평문) 페어 —
    /// 비교용 키와 표시용 키를 분리하지 않고 catalog key를 그대로 식별자로 사용.
    private static let presetReasonKeys: [String] = [
        "ntd.giveup_sheet.reason.stress",
        "ntd.giveup_sheet.reason.schedule",
        "ntd.giveup_sheet.reason.interruption",
        "ntd.giveup_sheet.reason.condition"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("ntd.giveup_sheet.section.preset") {
                    // 가변 폭 chip group — 가로 스크롤 대신 wrap. 영문은 단어 길어 multi-line 자연스러움.
                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(Self.presetReasonKeys, id: \.self) { key in
                            reasonChip(catalogKey: key)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section("ntd.giveup_sheet.section.custom") {
                    TextField(
                        "ntd.giveup_sheet.input_placeholder",
                        text: $customText,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let desc = descriptionText, !desc.isEmpty {
                    Text(verbatim: desc)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("ntd.giveup_sheet.title")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
            .presentationBackground(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") { dismiss() }
                        .tint(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("ntd.giveup.confirm", role: .destructive) {
                        onConfirm(resolvedComment)
                        dismiss()
                    }
                }
            }
        }
        .appTint()
    }

    /// 최종 저장될 comment.
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
            // 같은 chip 다시 누르면 해제.
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
            NTDGiveUpSheet { comment in
                print("confirmed: \(comment ?? "nil")")
            }
        }
}
