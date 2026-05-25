import AVFoundation
import Combine
import Foundation
import Speech
import SwiftUI

// MARK: - SpeechRecognizer
//
// SFSpeechRecognizer + AVAudioEngine 래퍼.
// 라이브 transcription을 @Published transcript로 publish — UI에서 binding으로 follow.
//
// 권한 흐름:
//   1) SFSpeechRecognizer.requestAuthorization (음성인식)
//   2) AVAudioApplication.requestRecordPermission (마이크)
//   둘 다 허용돼야 startRecording 가능.
//
// 로케일: ko-KR 기본. 시스템이 ko 아니면 SFSpeechRecognizer(locale:)이 nil 반환 가능 → fallback 검사.
//
// iOS 17+: requiresOnDeviceRecognition 옵션으로 오프라인 인식. 한국어 on-device 지원되면 자동 사용.

@MainActor
final class SpeechRecognizer: ObservableObject {

    @Published private(set) var transcript: String = ""
    @Published private(set) var isRecording: Bool = false
    /// 마지막 오류 — UI 안내용. nil이면 정상.
    @Published private(set) var lastError: String?

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init(locale: Locale = Locale(identifier: "ko-KR")) {
        // ko-KR이 unsupported면 시스템 current로 fallback.
        if let r = SFSpeechRecognizer(locale: locale) {
            self.recognizer = r
        } else {
            self.recognizer = SFSpeechRecognizer(locale: .current)
        }
    }

    /// 음성인식 + 마이크 권한 둘 다 요청. 둘 다 허용되면 true.
    func requestPermissions() async -> Bool {
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return false }
        let micOK = await AVAudioApplication.requestRecordPermission()
        return micOK
    }

    /// 녹음 시작. 이미 녹음 중이면 no-op.
    /// 권한 미허용 / 인식기 사용 불가 시 lastError 설정 후 throws.
    func startRecording() throws {
        guard !isRecording else { return }
        guard let recognizer, recognizer.isAvailable else {
            lastError = String(localized: "speech.error.unavailable")
            throw SpeechError.unavailable
        }
        // 이전 task 정리.
        task?.cancel()
        task = nil

        // Audio session 구성 — record + measurement mode for clean voice capture.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // Recognition request.
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(iOS 13, *), recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        self.request = req

        // Mic input tap.
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
        transcript = ""
        lastError = nil

        // Recognition task.
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.teardown()
                }
            }
        }
    }

    /// 녹음 종료. transcript는 마지막 값 유지.
    func stopRecording() {
        guard isRecording else { return }
        request?.endAudio()
        teardown()
    }

    /// transcript 초기화 — 입력 필드 clear 후 다음 녹음 준비.
    func resetTranscript() {
        transcript = ""
    }

    private func teardown() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum SpeechError: Error {
    case unavailable
    case denied
}
