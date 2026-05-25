import Foundation
import UserNotifications

// MARK: - 로컬 알림 서비스
//
// UNUserNotificationCenter wrapper. 단순 schedule/cancel만 노출.
//
// 캘린더 트리거 + DateComponents에 timezone 미설정 → wall-clock semantics:
//   "5/22 9:00 알림"을 등록하면 fire 시점의 디바이스 timezone 기준 9시에 알림.
//   여행으로 timezone이 바뀌어도 현지 9시 보장.
//
// 절대 시각 (특정 instant 보존)이 필요하면 components.timeZone = .current로 지정 가능.
// MyDays의 todo/NTD는 모두 wall-clock이라 미설정 사용.

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        // foreground 배너 노출을 위해 delegate 등록 — 미설정이면 willPresent가 호출 안 되고 silent.
        // App.init에서 NotificationService.shared 한 번이라도 touch하면 여기서 setup 완료됨.
        center.delegate = self
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 앱이 foreground일 때도 배너 + 사운드 노출.
    /// iOS 기본은 silent (앱 internal 처리에 위임) — 사용자 피드백 일관성을 위해 배너 강제.
    /// `.list` 포함 → 시스템 알림 센터에도 누적.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    // MARK: - 권한

    /// 권한 요청 — 첫 호출 시 시스템 prompt. 사용자가 거부했어도 다시 호출하면 silent return.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// 현재 권한이 알림 가능한 상태인지. 미결정이면 prompt 시도.
    private func ensureAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return await requestAuthorization()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - schedule / cancel

    /// 캘린더 시간 기준 알림 등록. 같은 id로 재등록 시 OS가 기존 request 갱신.
    /// fire-and-forget — 비동기 등록, 결과는 무시 (실패 시 silent).
    func schedule(
        id: String,
        title: String,
        body: String,
        components: DateComponents
    ) {
        Task {
            guard await ensureAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    /// 지정 id들의 pending 알림 제거.
    func cancel(ids: [String]) {
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// 현재 pending 중인 모든 알림 id.
    func pendingIdentifiers() async -> [String] {
        let requests = await center.pendingNotificationRequests()
        return requests.map { $0.identifier }
    }

    /// 지정 prefix 중 하나로 시작하는 모든 pending 알림 제거.
    /// 반복 routine은 1개 Reminder당 여러 occurrence 알림(id="{rid}:{yyyyMMdd}")을 갖기 때문에,
    /// 정확한 id를 모두 추적하기보다 prefix로 일괄 cancel하는 게 정합성 유지에 안전.
    func cancel(matchingPrefixes prefixes: [String]) async {
        guard !prefixes.isEmpty else { return }
        let pending = await pendingIdentifiers()
        let toCancel = pending.filter { id in
            prefixes.contains { prefix in id.hasPrefix(prefix) }
        }
        cancel(ids: toCancel)
    }
}
