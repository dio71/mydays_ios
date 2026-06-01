import SwiftUI

// MARK: - EmptyStateView
//
// 진짜 empty (데이터 0개) 상태 표시. 큰 SF Symbol 아이콘 + 메시지.
// 필터/토글로 인한 부분 empty는 별도 (작은 emptyRow 유지).
//
// 일러스트는 호출 view의 탭 아이콘 그대로 — 사용자가 "어느 탭의 빈화면인지" 즉시 인지.
// 큰 size + accent 색으로 시각 강조.
//
// 메시지에 "(+)" 포함 시 inline SF Symbol(plus.circle.fill)로 자동 교체 — 사용자가 실제 보는 (+) FAB과
// 시각 연결. actionIconName으로 다른 symbol 지정 가능.

struct EmptyStateView: View {

    let iconName: String
    /// LocalizedStringKey (catalog 키). 내부에서 String(localized:)로 풀어서 "(+)" 마커 치환.
    let messageKey: String.LocalizationValue
    /// "(+)" 마커를 교체할 inline SF Symbol. 기본 plus.circle.fill.
    let actionIconName: String

    init(
        iconName: String,
        message: String.LocalizationValue,
        actionIconName: String = "plus.circle.fill"
    ) {
        self.iconName = iconName
        self.messageKey = message
        self.actionIconName = actionIconName
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: iconName)
                .font(.system(size: 96, weight: .light))
                .foregroundStyle(Color.accentColor)
            messageText
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    /// 메시지 안 "(+)" 마커를 SF Symbol Image로 inline 치환.
    /// 마커 없으면 plain Text. Text concat으로 inline 이미지 렌더 (markdown 의존 X).
    private var messageText: Text {
        let raw = String(localized: messageKey)
        let parts = raw.components(separatedBy: "(+)")
        guard parts.count == 2 else { return Text(raw) }
        return Text(parts[0])
            + Text(Image(systemName: actionIconName)).foregroundColor(Color.accentColor)
            + Text(parts[1])
    }
}
