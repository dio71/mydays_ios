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

    enum EndReason {
        case userStop
        case background
        case motion
    }

    var body: some View {
        ZStack {
            // 배경: 어두운 색 강제 (배터리 + 집중 환경).
            // target 도달 시 goalColor의 약한 톤으로 전환.
            backgroundColor
                .ignoresSafeArea()

            VStack(spacing: 32) {
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

                // 메인 메시지
                Text(targetReached ? "focus.session.target_reached" : "focus.session.in_progress")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))

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
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            motionObserver.stop()
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
        .onChange(of: currentAccumulatedMinutes()) { old, new in
            // target 도달 감지 — overshoot 허용이라 도달 후에도 계속 누적.
            // 도달 시 한 번만 haptic + 화면 색 전환.
            guard !targetReached, let target = item.activityTargetValueDouble, new >= target else { return }
            targetReached = true
            // success haptic
            let gen = UINotificationFeedbackGenerator()
            gen.notificationOccurred(.success)
        }
    }

    // MARK: - 색상

    private var backgroundColor: Color {
        if targetReached {
            return goalColor.opacity(0.4)
        }
        return Color.black
    }

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
