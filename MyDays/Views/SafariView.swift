import SwiftUI
import SafariServices

/// SFSafariViewController를 SwiftUI sheet로 띄우기 위한 래퍼.
/// 개인정보처리방침 등 호스팅된 웹 문서를 앱 내에서 표시 (외부 Safari로 이탈하지 않음).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// 앱에서 사용하는 외부 법적 문서 링크.
/// 호스팅 완료 후 아래 URL 문자열만 실제 주소로 교체하면 됨.
enum AppLinks {
    /// 개인정보처리방침. 사용자 언어에 따라 ko/en 페이지 분기.
    static var privacyPolicy: URL {
        let isKorean = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
        let urlString = isKorean
            ? "https://app.snapplay.io/docs/mydays_privacy_policy.ko.html"
            : "https://app.snapplay.io/docs/mydays_privacy_policy.en.html"
        // URL 파싱 실패 시 방어적으로 영문 페이지 fallback.
        return URL(string: urlString)
            ?? URL(string: "https://app.snapplay.io/docs/mydays_privacy_policy.en.html")!
    }
}
