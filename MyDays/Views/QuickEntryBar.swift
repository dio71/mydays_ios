import SwiftUI

// MARK: - QuickEntryBar
//
// 보관함 하단 inline 입력 바.
// [TextField + mic 버튼 + (+) 버튼]
// - 키보드 입력 또는 마이크 탭 → 음성인식 → TextField 채움
// - (+) 또는 키보드 return → 제출(onSubmit). 제출 후 텍스트 clear
// - 마이크는 toggle: idle(line) ↔ recording(fill + accent)
//
// 권한 미허용 시 안내 alert. 첫 탭 시 권한 요청 prompt.

struct QuickEntryBar: View {

    @Binding var text: String
    /// 텍스트 비어있지 않을 때 호출. text reset은 QuickEntryBar가 책임짐 (호출 측에서 안 해도 됨).
    var onSubmit: () -> Void
    /// (+) 버튼 탭 시 텍스트가 비어있을 때 호출 — 상세 입력 폼 띄우는 용도. nil이면 비활성과 동일.
    var onEmptyTap: (() -> Void)? = nil

    @StateObject private var speech = SpeechRecognizer()
    @FocusState private var fieldFocused: Bool
    @State private var showPermissionAlert = false
    /// 녹음 시작 시점의 기존 텍스트 — voice transcript를 뒤에 append하기 위해 보존.
    @State private var keyboardPrefix: String = ""

    var body: some View {
        // 플로팅 카드 — 전체 입력 바를 단일 Capsule로 감싸고 shadow + 가장자리 여백.
        // 탭바와 분리된 floating element 느낌.
        HStack(spacing: 10) {
            // 입력 필드 — 내부 darker capsule 배경.
            HStack(spacing: 6) {
                TextField("archive.entry.placeholder", text: $text, axis: .horizontal)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .submitLabel(.send)
                    .onSubmit { submit() }
                if fieldFocused && !speech.isRecording {
                    Button { fieldFocused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.body)
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color(.tertiarySystemFill)))

            // 마이크 — 키보드가 안 떠있을 때만 노출.
            // 키보드 활성 시엔 시스템 키보드의 내장 dictation 버튼을 사용 (inline·자연스러움).
            // 우리 마이크는 "키보드 없이 voice만으로 빠르게 입력"하는 hands-free 경로 제공.
            if !fieldFocused {
                Button { toggleMic() } label: {
                    Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                        .font(.title2)
                        .foregroundStyle(speech.isRecording ? Color.accentColor : Color.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }

            // (+) — 목록탭 FAB와 동일 사이즈/색 (56pt accent, white plus, shadow). 항상 활성.
            // 텍스트 있으면 quickSave (등록 후 키보드/필드 clear), 비어있으면 onEmptyTap (상세 입력 폼).
            Button {
                if text.trimmed.isEmpty {
                    onEmptyTap?()
                } else {
                    submit()
                }
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.accentColor))
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
        // outer padding은 (+) 위치를 Today/List FAB(.padding(20))와 동일하게 맞추기 위해 계산:
        // (+) 우측 = outer trailing(14) + inner trailing(6) = 20pt from screen right
        // (+) 하단 = outer bottom(14) + inner vertical(6) = 20pt from safe area bottom
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        // 녹음 중 transcript 변화를 text에 반영. 기존 키보드 입력은 prefix로 보존하고 voice 결과를 뒤에 합침.
        .onChange(of: speech.transcript) { _, new in
            guard speech.isRecording else { return }
            if keyboardPrefix.isEmpty {
                text = new
            } else if new.isEmpty {
                text = keyboardPrefix
            } else {
                text = keyboardPrefix + " " + new
            }
        }
        // 녹음 중 사용자가 text field 탭하면 자동으로 녹음 종료 — 음성/키보드 동시 입력 충돌 방지.
        // 현재까지 transcript는 text에 보존되어 있으므로 사용자는 이어서 타이핑 가능.
        .onChange(of: fieldFocused) { _, focused in
            if focused && speech.isRecording {
                speech.stopRecording()
            }
        }
        .alert("speech.permission.title", isPresented: $showPermissionAlert) {
            Button("common.ok") {}
        } message: {
            Text("speech.permission.message")
        }
    }

    /// 제출 — 등록 후 입력 필드 clear + 키보드/포커스 해제.
    /// onSubmit이 현재 text를 읽어 저장하고, 그 다음 QuickEntryBar가 reset 처리.
    private func submit() {
        guard !text.trimmed.isEmpty else { return }
        if speech.isRecording { speech.stopRecording() }
        onSubmit()
        text = ""
        speech.resetTranscript()
        fieldFocused = false
    }

    private func toggleMic() {
        if speech.isRecording {
            speech.stopRecording()
            return
        }
        // 키보드 닫기 — 마이크 모드에선 키보드 안 띄움.
        fieldFocused = false
        // 기존 입력 보존 — voice transcript는 뒤에 append.
        keyboardPrefix = text.trimmed
        Task {
            let ok = await speech.requestPermissions()
            guard ok else {
                showPermissionAlert = true
                return
            }
            do {
                try speech.startRecording()
            } catch {
                showPermissionAlert = true
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
