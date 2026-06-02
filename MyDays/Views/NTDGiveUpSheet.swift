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
    /// 선택된 chip 식별자 — preset이면 catalog key, user reason이면 raw 텍스트.
    /// nil이면 chip 미선택.
    @State private var selectedKey: String?
    @State private var customText: String = ""
    /// 사용자가 "선택 항목에 추가"로 저장한 사유들. CSV가 아닌 UnitSeparator(\u{1F})로 join — 사용자 입력에 콤마 가능.
    @AppStorage("user_reasons.ntd_giveup") private var userReasonsRaw: String = ""

    /// preset 사유 chip 목록. (LocalizedStringKey, NSLocalizedString 평문) 페어 —
    /// 비교용 키와 표시용 키를 분리하지 않고 catalog key를 그대로 식별자로 사용.
    private static let presetReasonKeys: [String] = [
        "ntd.giveup_sheet.reason.stress",
        "ntd.giveup_sheet.reason.schedule",
        "ntd.giveup_sheet.reason.interruption",
        "ntd.giveup_sheet.reason.condition"
    ]

    /// 사용자 추가 사유 목록 (정렬: 추가 순).
    private var userReasons: [String] {
        userReasonsRaw.split(separator: "\u{1F}", omittingEmptySubsequences: true).map(String.init)
    }

    /// 사용자 입력 텍스트를 chip 목록에 추가 + customText 비움 + 새 chip 자동 선택.
    private func addUserReason() {
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = userReasons
        guard !list.contains(trimmed) else {
            // 이미 있으면 추가 안 함 — 그 chip만 선택 표시.
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
                Section("ntd.giveup_sheet.section.preset") {
                    // 가변 폭 chip group — 가로 스크롤 대신 wrap. 영문은 단어 길어 multi-line 자연스러움.
                    // preset + 사용자 추가 사유 모두 같은 시각 (raw text가 식별자).
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
                Section("ntd.giveup_sheet.section.custom") {
                    TextField(
                        "ntd.giveup_sheet.input_placeholder",
                        text: $customText,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    // "선택 항목에 추가" — 사용자 입력 trimmed가 있으면 활성. 탭 시 chip 추가 + 자동 선택.
                    addReasonButton
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
    /// customText 우선, 비어 있으면 선택된 chip 텍스트(preset이면 localized, user면 raw), 둘 다 없으면 nil.
    private var resolvedComment: String? {
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let key = selectedKey {
            // preset key면 localize, 그 외(user reason raw text)는 그대로.
            if Self.presetReasonKeys.contains(key) {
                return NSLocalizedString(key, comment: "")
            }
            return key
        }
        return nil
    }

    /// "선택 항목에 추가" 버튼 — chip outline 스타일과 통일 (capsule stroke + accent + plus 아이콘).
    /// 사용자 입력 trimmed 없으면 dim 처리(opacity 0.4) + 탭 차단.
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

    /// identifier: preset이면 catalog key, user reason이면 raw 텍스트. selectedKey 비교 식별자.
    /// label: 화면 표시 문구 (preset은 localized, user는 raw).
    private func reasonChip(identifier: String, label: String) -> some View {
        let isSelected = selectedKey == identifier
        return Button {
            // 같은 chip 다시 누르면 해제.
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
            NTDGiveUpSheet { comment in
                print("confirmed: \(comment ?? "nil")")
            }
        }
}
