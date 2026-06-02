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
    /// 보조 메시지 (선택) — main 아래 작은 글자로 노출. nil이면 hide. "(+)" 마커 동일 처리.
    let hintKey: String.LocalizationValue?
    /// "(+)" 마커를 교체할 inline SF Symbol. 기본 plus.circle.fill.
    let actionIconName: String
    /// 콘텐츠 정렬 — 기본 center. `.top`이면 상단 정렬 + 위쪽 padding 추가 (Section 위에 메시지 + 그 아래
    /// 완료 섹션 같이 노출하는 케이스용).
    let alignment: Alignment
    /// `.top` 모드 위쪽 padding. 기본 140. 호출 측 상단에 다른 UI(예: WeekStrip)가 있으면 작게 override.
    let topPadding: CGFloat

    init(
        iconName: String,
        message: String.LocalizationValue,
        hint: String.LocalizationValue? = nil,
        actionIconName: String = "plus.circle.fill",
        alignment: Alignment = .center,
        topPadding: CGFloat = 140
    ) {
        self.iconName = iconName
        self.messageKey = message
        self.hintKey = hint
        self.actionIconName = actionIconName
        self.alignment = alignment
        self.topPadding = topPadding
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: iconName)
                .font(.system(size: 96, weight: .light))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 10) {
                renderMessage(messageKey)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let hintKey {
                    renderMessage(hintKey)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .padding(.horizontal, 40)
        .padding(.top, isTop ? topPadding : 0)
    }

    private var isTop: Bool {
        switch alignment {
        case .top, .topLeading, .topTrailing: return true
        default: return false
        }
    }

    /// 메시지 안 "(+)" 마커를 SF Symbol Image로 inline 치환. 마커 없으면 plain Text.
    private func renderMessage(_ key: String.LocalizationValue) -> Text {
        let raw = String(localized: key)
        let parts = raw.components(separatedBy: "(+)")
        guard parts.count == 2 else { return Text(raw) }
        return Text(parts[0])
            + Text(Image(systemName: actionIconName)).foregroundColor(Color.accentColor)
            + Text(parts[1])
    }
}
