import SwiftUI
import MessageUI

// MARK: - 피드백 메일
//
// 버그 신고 / 건의하기 — 인앱 작성(MFMailComposeViewController) + mailto fallback.
// 수신: devman@snapplay.io. 본문에 진단 정보(버전·iOS·기기) 자동 첨부.

enum FeedbackMail {
    static let recipient = "devman@snapplay.io"
    static var subject: String { NSLocalizedString("feedback.subject", comment: "") }

    /// 메일 본문 — 사용자 작성 영역 + 진단 정보(수정 안내).
    static func body() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        let os = UIDevice.current.systemVersion
        let model = deviceModelIdentifier()
        let prefix = NSLocalizedString("feedback.body_prefix", comment: "")
        let diagLabel = NSLocalizedString("feedback.diagnostics", comment: "")
        return "\(prefix)\n\n\n---\n\(diagLabel)\nMyDays \(version) (\(build)) · iOS \(os) · \(model)"
    }

    /// mailto URL (인앱 작성 불가 시 fallback).
    static func mailtoURL() -> URL? {
        let subj = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let bod = body().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "mailto:\(recipient)?subject=\(subj)&body=\(bod)")
    }

    /// 하드웨어 식별자 (예: iPhone15,2). 실패 시 UIDevice.model.
    private static func deviceModelIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        let id = withUnsafeBytes(of: &sys.machine) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        return id.isEmpty ? UIDevice.current.model : id
    }
}

// MARK: - MFMailComposeViewController 래퍼

struct MailComposeView: UIViewControllerRepresentable {
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([FeedbackMail.recipient])
        vc.setSubject(FeedbackMail.subject)
        vc.setMessageBody(FeedbackMail.body(), isHTML: false)
        return vc
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            onDismiss()
        }
    }
}
