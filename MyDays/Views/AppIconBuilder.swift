import SwiftUI

// MARK: - App Icon Builder (dev 도구)
//
// SwiftUI로 앱 아이콘 시안을 렌더해 PNG로 export.
// ImageRenderer(iOS 16+) 사용 — 1024×1024 PNG를 caches dir에 저장.
// Settings → Dev 섹션에서 호출. ShareLink로 Files/AirDrop/메시지 등으로 빼낼 수 있음.
//
// 색·아이콘 조정은 AppIconView 안의 private 상수만 바꾸면 됨.
// 결과 PNG는 iOS 시스템 마스크가 자동 적용되므로 source는 사각형 그대로 두는 게 표준.

struct AppIconView: View {

    let size: CGFloat

    // 디자인 조정 지점 ----------------------------------------------------
    /// 왼쪽 절반 배경 (파스텔 파랑) — todo 영역.
    private var leftColor: Color { Color(red: 0.384, green: 0.604, blue: 0.871) }
    /// 오른쪽 절반 배경 (거의 흰색 + 파란 hint) — NTD/시간 영역.
    private var rightColor: Color { Color(red: 0.94, green: 0.97, blue: 1.0) }
    /// 왼쪽 글리프 — 흰 체크.
    private var checkColor: Color { .white }
    private var leftSymbol: String { "checkmark" }
    /// 오른쪽 글리프 — 파스텔 파랑 알람 outline (왼쪽 배경과 같은 톤).
    private var clockColor: Color { Color(red: 0.384, green: 0.604, blue: 0.871) }
    private var rightSymbol: String { "alarm" }
    // ---------------------------------------------------------------------

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                leftColor.frame(width: size * 0.5)
                rightColor.frame(width: size * 0.5)
            }
            HStack(spacing: 0) {
                Image(systemName: leftSymbol)
                    .font(.system(size: size * 0.28, weight: .bold))
                    .foregroundStyle(checkColor)
                    .frame(width: size * 0.5)
                Image(systemName: rightSymbol)
                    .font(.system(size: size * 0.28, weight: .regular))
                    .foregroundStyle(clockColor)
                    .frame(width: size * 0.5)
            }
        }
        .frame(width: size, height: size)
    }
}

enum AppIconBuilder {
    /// 현재 AppIconView를 PNG로 렌더해 caches에 저장 후 URL 반환.
    @MainActor
    static func exportPNG(size: CGFloat = 1024) -> URL? {
        let renderer = ImageRenderer(content: AppIconView(size: size))
        renderer.scale = 1  // ImageRenderer는 scale 곱해서 키우므로 1로 고정.
        guard let uiImage = renderer.uiImage,
              let data = uiImage.pngData() else { return nil }
        let url = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppIcon_\(Int(size)).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            assertionFailure("App icon export failed: \(error)")
            return nil
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        AppIconView(size: 180)
            .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        AppIconView(size: 80)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .padding()
}
