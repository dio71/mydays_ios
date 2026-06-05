import SwiftUI
import CoreMotion
import CoreData
import Combine

// MARK: - FocusSessionView
//
// 집중 세션 fullScreen UI. 사용자가 ▶ 버튼 누르면 modal 표시.
//
// 정책:
// - **Strict foreground required** — scenePhase=.background 시 자동 세션 종료
// - **Motion 감지** — Core Motion deviceMotion. sliding window 3초 평균 가속도 > 임계치면 종료
// - **Idle timer disable** — 화면 자동 잠금 방지 (사용자가 의도치 않게 종료되는 케이스 회피)
// - **시간 표시 없음** — zen mode. title + "지금 집중하고 있어요" + caption 2줄만
// - **Target 도달** — 화면 색 변환 (어두운 → goalColor) + haptic success. overshoot 허용 (계속 누적)
// - **Stop** — 하단 작은 버튼. 충동 정지 방지하지만 누를 수는 있음
//
// 세션 종료 시:
//   FocusSessionManager.stopSession() 호출 → elapsed 계산 → ≥10분이면 RC 누적, 미만이면 폐기

struct FocusSessionView: View {

    @ObservedObject var item: Item
    let occurrenceDate: Date

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var motionObserver = MotionObserver()
    @State private var targetReached = false
    @State private var hasInitialized = false

    /// 정지 사유 — UI에 안내 메시지 표시용 (현재 미사용, 향후 toast 등)
    @State private var endReason: EndReason? = nil

    /// target 도달 자동 트리거 task — 세션 시작 시 (target - 누적)분 만큼 sleep 후 한 번만 fire.
    /// dismiss / 다른 종료 시 cancel — 가드 + 자원 정리.
    /// (이전엔 5초 polling timer였음 — wasteful. 도달 시점은 결정적이라 single delayed trigger로 충분.)
    @State private var targetTask: Task<Void, Never>?

    enum EndReason {
        case userStop
        case background
        case motion
    }

    var body: some View {
        ZStack {
            // 배경: 항상 어두운 색 강제 (배터리 + 집중 환경).
            // target 도달 시 배경은 그대로 두고 "달성!" 문구만 capsule(밝은 배경)로 시각 강조 → 화면 전체 변화로 인한 산만 회피.
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 32) {
                // 상단 현재 시간 — 락스크린 느낌 (날짜 + 큰 시각). 타이머 아님(분 단위 갱신).
                // 오전/오후는 작게, 시각은 크게 분리. 톤은 회색.
                TimelineView(.everyMinute) { context in
                    let parts = clockParts(context.date)
                    VStack(spacing: 2) {
                        Text(context.date, format: .dateTime.weekday(.wide).month().day())
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if !parts.period.isEmpty {
                                Text(parts.period)
                                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                            }
                            Text(parts.time)
                                .font(.system(size: 64, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(.top, 60)

                Spacer()

                // 목표 아이콘 (작게, 회색 톤 — 산만 방지)
                if let iconName = item.iconName.flatMap(GoalIcon.init(rawValue:))?.symbolName {
                    Image(systemName: iconName)
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(.white.opacity(0.3))
                }

                // 항목 제목 (사용자 정의 — 공부 2시간, 명상 1시간 등)
                Text(item.title ?? "")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // 메인 메시지 — target 도달 시 goalColor capsule + 흰 글자로 강조, 그 외엔 plain text.
                // 달성 capsule은 tappable — 하단 종료 버튼과 동일하게 세션 종료 + dismiss.
                // (자연스러운 finish 흐름: 달성 표시 직접 탭으로 마무리)
                if targetReached {
                    Button(action: userStop) {
                        Text("focus.session.target_reached")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(goalColor))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("focus.session.in_progress")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()

                // 안내 caption
                VStack(spacing: 6) {
                    Text("focus.session.hint.keep_screen")
                    Text("focus.session.hint.terminate_conditions")
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

                // 종료 버튼 — 작게, 충동 정지 방지.
                Button(action: userStop) {
                    Text("focus.session.stop")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(.white.opacity(0.1))
                        )
                }
                .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true
            // 시작 시점에 manager 통해 active 등록.
            // (TodayView에서 시작 직전 startSession 호출했을 수도 있으니 중복 시작 방지 위해 manager에서 처리)
            FocusSessionManager.shared.startSession(item: item, occurrenceDate: occurrenceDate)
            UIApplication.shared.isIdleTimerDisabled = true
            motionObserver.start()
            scheduleTargetReachedTrigger()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            motionObserver.stop()
            targetTask?.cancel()
            targetTask = nil
        }
        .onChange(of: scenePhase) { _, newPhase in
            // .background = 잠금/홈/앱 전환/전화 받음 → 세션 종료.
            // .inactive (transient overlay — 알림 배너, Siri, 전화 안 받음 등)는 무시.
            if newPhase == .background {
                terminate(reason: .background)
            }
        }
        .onChange(of: motionObserver.thresholdExceeded) { _, exceeded in
            if exceeded {
                terminate(reason: .motion)
            }
        }
    }

    /// target 도달 자동 트리거 — 세션 시작 시 한 번만 schedule.
    /// 남은 시간 = target - 현재 누적. 0 이하면 진입 즉시 도달 상태로 마킹.
    /// dismiss / terminate 시 onDisappear에서 cancel — fire 안 됨.
    private func scheduleTargetReachedTrigger() {
        // effective target — RC.targetSnapshot 우선 (사용자가 target 변경해도 이 세션은 시작 시점 기준).
        guard let target = item.effectiveTargetValue(on: occurrenceDate) else { return }
        let stored = item.focusCurrentMinutes(on: occurrenceDate)
        let remainingMinutes = target - stored
        if remainingMinutes <= 0 {
            // 진입 시점에 이미 도달 — 즉시 마킹 (haptic은 새 도달이 아니라 생략).
            targetReached = true
            return
        }
        let delaySeconds = remainingMinutes * 60
        targetTask = Task {
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !targetReached else { return }
                targetReached = true
                let gen = UINotificationFeedbackGenerator()
                gen.notificationOccurred(.success)
            }
        }
    }

    // MARK: - 시계 포맷

    /// 현재 시각을 (오전/오후, 시:분)로 분리 — 시스템 12/24h 설정 반영.
    /// 24h면 period는 빈 문자열.
    private func clockParts(_ date: Date) -> (period: String, time: String) {
        let locale = Locale.current
        let is24h = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?.contains("a") == false
        let timeFmt = DateFormatter()
        timeFmt.locale = locale
        // 고정 포맷 — 템플릿("hmm")은 ko에서 오전/오후를 포함해 period 중복됨. 시각만.
        timeFmt.dateFormat = is24h ? "H:mm" : "h:mm"
        let periodFmt = DateFormatter()
        periodFmt.locale = locale
        periodFmt.setLocalizedDateFormatFromTemplate("a")
        return (is24h ? "" : periodFmt.string(from: date), timeFmt.string(from: date))
    }

    // MARK: - 색상

    private var goalColor: Color {
        guard let raw = item.iconColorHex,
              let cc = CategoryColor(rawValue: raw) else { return Color.accentColor }
        return cc.color
    }

    // MARK: - 누적 계산 (live)

    /// 현재까지 누적 분 — 기존 RC + 현재 진행 세션의 elapsed.
    /// onChange 트리거를 위해 매 body 평가에 호출됨.
    /// 실시간 갱신은 TimelineView 없이 SwiftUI의 일반 invalidation에 의존 — 충분히 reactive.
    private func currentAccumulatedMinutes() -> Double {
        let stored = item.focusCurrentMinutes(on: occurrenceDate)
        guard let started = FocusSessionManager.shared.sessionStartedAt else { return stored }
        let elapsed = Date().timeIntervalSince(started) / 60.0
        return stored + elapsed
    }

    // MARK: - 종료

    private func userStop() {
        terminate(reason: .userStop)
    }

    private func terminate(reason: EndReason) {
        guard endReason == nil else { return }  // 중복 호출 방지
        endReason = reason
        _ = FocusSessionManager.shared.stopSession()
        dismiss()
    }
}

// MARK: - MotionObserver
//
// Core Motion device-motion 모니터링. sliding window로 평균 가속도 magnitude 계산.
// 임계치 초과 시 thresholdExceeded=true publish — view가 onChange로 종료.
//
// MVP 임계치: 평균 0.5g 이상 (3초 윈도우). 실측 조정 필요.
// 정지된 폰: 평균 ~0g (중력 제거된 user acceleration 사용). 흔들거나 들고 다니면 spike.

@MainActor
final class MotionObserver: ObservableObject {

    @Published var thresholdExceeded: Bool = false

    private let manager = CMMotionManager()
    /// sliding window — 최근 N개 sample magnitude 보관 (3초 / updateInterval).
    private var samples: [Double] = []
    private let windowSeconds: TimeInterval = 3
    private let updateInterval: TimeInterval = 0.2
    /// 평균 magnitude 임계치 (g). 실측 후 조정.
    private let thresholdG: Double = 0.5

    private var maxSamples: Int { Int(windowSeconds / updateInterval) }

    func start() {
        thresholdExceeded = false
        samples.removeAll()
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = updateInterval
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            let a = m.userAcceleration
            let mag = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            self.samples.append(mag)
            if self.samples.count > self.maxSamples {
                self.samples.removeFirst(self.samples.count - self.maxSamples)
            }
            guard self.samples.count >= self.maxSamples else { return }
            let avg = self.samples.reduce(0, +) / Double(self.samples.count)
            if avg > self.thresholdG {
                self.thresholdExceeded = true
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        samples.removeAll()
    }
}
