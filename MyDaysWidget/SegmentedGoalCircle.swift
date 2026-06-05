import SwiftUI
import WidgetKit

// MARK: - SegmentedGoalCircle
//
// 락스크린 위젯용 — 원 1개를 활성 목표 수(1~4)만큼 분할해 각 목표의 아이콘 + 진행 호 표시.
//  1개 = 풀 원 (중앙 아이콘)
//  2개 = 좌/우 반원
//  3개 = 120° × 3 (상 / 우하 / 좌하)
//  4개 = 사분면 (상 / 우 / 하 / 좌)
//
// 락스크린은 시스템이 단색(틴트)으로 강제 렌더 → 목표별 색 구분 불가. 아이콘 + 호로만 구분.
// circular(원 1개) / rectangular(slot당 원) 양쪽에서 재사용.

struct SegmentedGoalCircle: View {
    /// 표시할 목표 (최대 4개 사용; 초과분은 호출 측에서 잘라 전달).
    let snapshots: [ItemSnapshot]
    /// true = 목표별 색상 사용(홈 위젯). false = widgetAccentable 단색(락스크린).
    var colored: Bool = false

    private var count: Int { min(max(snapshots.count, 1), 4) }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                if snapshots.isEmpty {
                    Image(systemName: "scope")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(snapshots.prefix(4).enumerated()), id: \.offset) { idx, snap in
                        segment(snap, index: idx, side: side)
                    }
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 분할별 배치 파라미터

    /// 각 segment 아이콘이 놓일 중심각(도). 0°=3시, 시계방향. -90°=12시(상).
    private func centroids(_ n: Int) -> [Double] {
        switch n {
        case 1: return [-90]                    // 중앙(아이콘은 offset 0)
        case 2: return [180, 0]                 // 좌, 우
        case 3: return [-90, 30, 150]           // 상, 우하, 좌하
        default: return [-135, -45, 45, 135]    // 좌상, 우상, 우하, 좌하 — 경계 +자(수직·수평)
        }
    }

    /// 아이콘 — colored면 목표 색, 아니면 widgetAccentable.
    @ViewBuilder
    private func iconView(_ snap: ItemSnapshot, size: CGFloat, color: Color) -> some View {
        if colored {
            Image(systemName: snap.iconName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(color)
        } else {
            Image(systemName: snap.iconName)
                .font(.system(size: size, weight: .medium))
                .widgetAccentable()
        }
    }

    private func iconSize(_ n: Int) -> CGFloat { [22, 15, 13, 11][n - 1] }
    /// 아이콘 중심까지의 반경(지름 대비). 0=중앙. 너무 크면 아이콘이 호/경계까지 밀림.
    /// (지름×factor = 중심으로부터 거리. 반지름의 ~40~52%만 사용.)
    private func iconRadiusFactor(_ n: Int) -> CGFloat { [0, 0.17, 0.21, 0.21][n - 1] }

    // MARK: segment 1개 (트랙 호 + 진행 호 + 아이콘)

    @ViewBuilder
    private func segment(_ snap: ItemSnapshot, index: Int, side: CGFloat) -> some View {
        let n = count
        let sweepFull = 360.0 / Double(n)
        let gap: Double = (n == 1) ? 0 : 12
        let centroid = centroids(n)[index]
        // n=1은 풀 원 → 12시(-90°)에서 시작해 시계방향. (centroid 공식대로면 6시에서 시작됨)
        let start: Double = (n == 1) ? -90 : (centroid - sweepFull / 2 + gap / 2)
        let sweep: Double = (n == 1) ? 360 : (sweepFull - gap)
        let progress = max(0, min(snap.progress, 1))

        let rad = centroid * .pi / 180
        let iconR = side * iconRadiusFactor(n)

        // colored(홈 위젯)는 채도 톤다운 — 카테고리 vivid 색이 위젯에서 너무 쨍해 보임. 락은 단색이라 무관.
        let color = colored ? snap.resolvedColor().desaturated(0.7) : snap.resolvedColor()
        ZStack {
            // 트랙 — 전체 wedge, 흐리게 (분할 경계 인지용).
            WedgeArc(startDeg: start, sweepDeg: sweep, fraction: 1)
                .stroke(style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .opacity(0.22)
                .padding(3)
            // 진행 호 — colored면 목표 색, 아니면 widgetAccentable 단색.
            if colored {
                WedgeArc(startDeg: start, sweepDeg: sweep, fraction: progress)
                    .stroke(style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .foregroundStyle(color)
                    .padding(3)
            } else {
                WedgeArc(startDeg: start, sweepDeg: sweep, fraction: progress)
                    .stroke(style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .padding(3)
                    .widgetAccentable()
            }
            // 아이콘.
            iconView(snap, size: iconSize(n), color: color)
                .offset(x: iconR * cos(rad), y: iconR * sin(rad))
        }
    }
}

// MARK: - WedgeArc

/// 시작각(startDeg)에서 sweepDeg만큼의 호 중 fraction(0~1)만큼을 그리는 Shape.
/// 각도는 도(degree), 0°=3시 방향, 시계방향 증가(화면 좌표 — y 아래).
private struct WedgeArc: Shape {
    let startDeg: Double
    let sweepDeg: Double
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let f = max(0, min(fraction, 1))
        p.addArc(
            center: c,
            radius: r,
            startAngle: Angle(degrees: startDeg),
            endAngle: Angle(degrees: startDeg + sweepDeg * f),
            clockwise: false
        )
        return p
    }
}

// MARK: - Preview

#Preview("2분할", as: .accessoryCircular) {
    MyDaysLockCircleWidget()
} timeline: {
    GoalLockCircleEntry(date: .now, snapshots: [
        ItemSnapshot(id: "1", kind: .notTodo, title: "단식", bucket: .ongoing, progress: 0.6,
                     sortAnchor: .now, iconName: "fork.knife", iconColorHex: "blue"),
        ItemSnapshot(id: "2", kind: .activity, title: "걷기", bucket: .ongoing, progress: 0.3,
                     sortAnchor: .now, iconName: "figure.walk", iconColorHex: "green"),
    ])
}
