import SwiftUI
import UIKit

/// UIActivityViewController를 SwiftUI sheet로 띄우는 래퍼 (파일 공유 등).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
