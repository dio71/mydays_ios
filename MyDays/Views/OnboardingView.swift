import SwiftUI

// MARK: - OnboardingView
//
// 첫 launch 1회 노출되는 onboarding 화면.
// 5 페이지 — 4종 기능 소개 + 마지막에 권한 안내.
// 실제 권한 요청은 X — 각 권한은 해당 기능을 처음 사용하는 시점에 contextual prompt.
//
// 흐름: 할일 → 목표 → 오늘+위젯 → Inbox → 권한 안내 → "시작하기".
// 상단 우측 "건너뛰기"로 권한 페이지로 점프 가능.
// 하단 dot indicator + 다음/시작하기 버튼.
//
// "시작하기" 탭 → @AppStorage(onboardingShown)=true → RootView 전환.

struct OnboardingView: View {

    let onContinue: () -> Void
    @State private var page: Int = 0

    private let totalPages = 5
    private var lastPage: Int { totalPages - 1 }

    var body: some View {
        VStack(spacing: 0) {
            // 상단 — 건너뛰기 (마지막 페이지에선 숨김).
            HStack {
                Spacer()
                if page < lastPage {
                    Button {
                        withAnimation { page = lastPage }
                    } label: {
                        Text("onboarding.skip")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 28)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            TabView(selection: $page) {
                OnboardingTodoPage().tag(0)
                OnboardingInboxPage().tag(1)
                OnboardingGoalPage().tag(2)
                OnboardingTodayWidgetPage().tag(3)
                OnboardingPermissionsPage().tag(lastPage)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .indexViewStyle(.page(backgroundDisplayMode: .never))
            .animation(.easeInOut, value: page)

            // 하단 — dot indicator + CTA 버튼.
            VStack(spacing: 20) {
                HStack(spacing: 8) {
                    ForEach(0..<totalPages, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .animation(.easeInOut(duration: 0.2), value: page)
                    }
                }

                Button {
                    if page < lastPage {
                        withAnimation { page += 1 }
                    } else {
                        onContinue()
                    }
                } label: {
                    Text(page < lastPage ? "onboarding.next" : "onboarding.cta")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.accentColor)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - 공통 page layout
//
// 모든 기능 page는 동일 구조 — 상단 illustration + headline + body.
// illustration은 호출 측에서 @ViewBuilder로 주입.

private struct OnboardingFeaturePage<Illustration: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let illustration: () -> Illustration

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            illustration()
                .frame(maxWidth: .infinity)
                .frame(height: 280)
            VStack(spacing: 12) {
                Text(title)
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 일러스트 helpers
//
// 단순화된 placeholder bar/circle/square. 실제 ItemRow·위젯 컴포넌트 재활용 X —
// onboarding 전용 일러스트.

/// 가로 막대 placeholder — 텍스트 자리 표현.
private struct PlaceholderBar: View {
    let width: CGFloat
    let height: CGFloat = 8
    var color: Color = .secondary
    var opacity: Double = 0.3
    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(color.opacity(opacity))
            .frame(width: width, height: height)
    }
}

/// 일러스트 카드 컨테이너 — 둥근 모서리 + 미묘한 그림자.
private struct IllustrationCard<Content: View>: View {
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var padding: CGFloat = 16
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(padding)
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
    }
}

// MARK: - 페이지 1: 할일 + 반복 + 체크리스트

private struct OnboardingTodoPage: View {
    var body: some View {
        OnboardingFeaturePage(
            title: "onboarding.feature.todo.title",
            subtitle: "onboarding.feature.todo.body"
        ) {
            IllustrationCard(width: 280) {
                // row 1: 반복 todo — 반복 주기 텍스트 + 오른쪽 D-day 라벨.
                HStack(spacing: 12) {
                    Image(systemName: "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        PlaceholderBar(width: 140)
                        HStack(spacing: 6) {
                            Image(systemName: "flag.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.yellow)
                            Image(systemName: "repeat")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.accentColor)
                            Text("onboarding.mockup.recurrence.weekly_mon_wed")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Spacer()
                    Text(verbatim: "D-2")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Divider().opacity(0.4)
                // row 2: 체크리스트 펼침 상태 — 부모 + 3개 sub-item (2개 완료).
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            PlaceholderBar(width: 180)
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.square")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(verbatim: "2/3")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    // 펼친 sub-items — leadingControl 폭(=18 + 12 spacing)만큼 indent.
                    VStack(alignment: .leading, spacing: 8) {
                        checklistSubItem(checked: true, width: 140)
                        checklistSubItem(checked: true, width: 120)
                        checklistSubItem(checked: false, width: 150)
                    }
                    .padding(.leading, 30)
                }
                Divider().opacity(0.4)
                // row 3: 완료된 todo — filled check + priority 깃발(빨강) + 알림 아이콘.
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 6) {
                        PlaceholderBar(width: 140, opacity: 0.2)
                        HStack(spacing: 6) {
                            Image(systemName: "flag.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.red)
                            Image(systemName: "bell")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func checklistSubItem(checked: Bool, width: CGFloat) -> some View {
        HStack(spacing: 10) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(checked ? Color.accentColor : .secondary)
            PlaceholderBar(width: width, opacity: checked ? 0.2 : 0.35)
            Spacer()
        }
    }
}

// MARK: - 페이지 2: 4-type 목표

private struct OnboardingGoalPage: View {
    var body: some View {
        OnboardingFeaturePage(
            title: "onboarding.feature.goal.title",
            subtitle: "onboarding.feature.goal.body"
        ) {
            IllustrationCard(width: 280) {
                // 절제 — 진행 중 + 🔥23 + 매일 + 16시간 + (x) 포기 버튼
                goalRow(
                    icon: "hand.raised.fill",
                    color: .red,
                    titleWidth: 70,
                    progress: 0.55,
                    done: false,
                    streak: 23,
                    metaText: "onboarding.mockup.recurrence.daily",
                    metaTrailingIcon: "clock",
                    metaTrailingText: "onboarding.mockup.duration.16h",
                    actionIcon: "xmark.circle"
                )
                Divider().opacity(0.4)
                // 활동 — 완료 + 🔥72 + auto source heart filled
                goalRow(
                    icon: "figure.run",
                    color: .orange,
                    titleWidth: 70,
                    progress: 1.0,
                    done: true,
                    streak: 72,
                    metaText: "onboarding.mockup.recurrence.weekdays",
                    metaTrailingIcon: nil,
                    metaTrailingText: nil,
                    actionIcon: "heart.fill"
                )
                Divider().opacity(0.4)
                // 집중 — 진행 중 + 🔥4 + ▶ start 버튼
                goalRow(
                    icon: "hourglass.bottomhalf.filled",
                    color: .indigo,
                    titleWidth: 70,
                    progress: 0.4,
                    done: false,
                    streak: 4,
                    metaText: "onboarding.mockup.recurrence.monthly_dates",
                    metaTrailingIcon: nil,
                    metaTrailingText: nil,
                    actionIcon: "play.circle"
                )
                Divider().opacity(0.4)
                // 습관 — 체크 안된 상태 + 🔥17 + 매일 + 알림
                habitRow(
                    color: .green,
                    titleWidth: 90,
                    streak: 17,
                    metaText: "onboarding.mockup.recurrence.daily",
                    hasReminder: true
                )
            }
        }
    }

    // MARK: - Row builders

    /// 절제/활동/집중 공통 row — leading icon circle + title + progress capsule + trailing action icon.
    /// done=true면 progress fully filled + opacity 살짝 낮춤 (완료 시각화).
    /// progress capsule은 항상 80pt 고정 폭 — 3 row 시각 통일.
    /// actionIcon: 진행바 오른쪽 trailing 아이콘 — 절제=(x), 활동=heart.fill(auto), 집중=▶.
    private func goalRow(
        icon: String,
        color: Color,
        titleWidth: CGFloat,
        progress: CGFloat,
        done: Bool,
        streak: Int,
        metaText: LocalizedStringKey,
        metaTrailingIcon: String?,
        metaTrailingText: LocalizedStringKey?,
        actionIcon: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            goalIcon(symbol: icon, color: color, done: done)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PlaceholderBar(width: titleWidth, opacity: done ? 0.2 : 0.35)
                    Spacer(minLength: 8)
                    progressCapsule(color: color, progress: progress, done: done)
                        .frame(width: 80)
                    Image(systemName: actionIcon)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                metaLine(
                    streak: streak,
                    metaText: metaText,
                    trailingIcon: metaTrailingIcon,
                    trailingText: metaTrailingText
                )
            }
        }
    }

    /// 습관 row — progress 대신 trailing의 unchecked square 체크 박스.
    /// 알림 켜진 상태(bell) 같이 표시.
    private func habitRow(
        color: Color,
        titleWidth: CGFloat,
        streak: Int,
        metaText: LocalizedStringKey,
        hasReminder: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            goalIcon(symbol: "checkmark.square.fill", color: color, done: false)
            VStack(alignment: .leading, spacing: 6) {
                PlaceholderBar(width: titleWidth)
                HStack(spacing: 6) {
                    streakBadge(streak)
                    Image(systemName: "repeat")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(metaText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if hasReminder {
                        Image(systemName: "bell")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "square")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Building blocks

    private func goalIcon(symbol: String, color: Color, done: Bool) -> some View {
        ZStack {
            Circle().fill(color.opacity(done ? 0.85 : 1.0))
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
    }

    private func progressCapsule(color: Color, progress: CGFloat, done: Bool) -> some View {
        let p = max(0, min(progress, 1))
        return ZStack(alignment: .leading) {
            Capsule().fill(Color(.tertiarySystemFill))
            GeometryReader { proxy in
                Capsule()
                    .fill(color.opacity(done ? 0.5 : 0.4))
                    .frame(width: proxy.size.width * p)
            }
        }
        .frame(height: 10)
    }

    @ViewBuilder
    private func metaLine(streak: Int, metaText: LocalizedStringKey, trailingIcon: String?, trailingText: LocalizedStringKey?) -> some View {
        HStack(spacing: 6) {
            streakBadge(streak)
            Image(systemName: "repeat")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(metaText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            // 반복 텍스트 바로 옆에 inline으로 trailing meta(시간 등) 표시 — 실제 ItemRow statusIcons 패턴.
            if let trailingIcon, let trailingText {
                Image(systemName: trailingIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(trailingText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 🔥 streak badge — flame.fill 오렌지 + 연속 일자 숫자.
    /// 실제 ItemRow statusIcons의 streak 패턴과 같은 시각.
    private func streakBadge(_ count: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.orange)
            Text(verbatim: "\(count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 페이지 3: 오늘 + 위젯

private struct OnboardingTodayWidgetPage: View {
    var body: some View {
        OnboardingFeaturePage(
            title: "onboarding.feature.today.title",
            subtitle: "onboarding.feature.today.body"
        ) {
            HStack(alignment: .top, spacing: 14) {
                // 오늘 화면 미니
                IllustrationCard(width: 170, height: 240, padding: 12) {
                    // weekstrip 7 dot
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { i in
                            ZStack {
                                if i == 3 {
                                    Circle().fill(Color.accentColor)
                                        .frame(width: 16, height: 16)
                                }
                                Text(verbatim: "\(15 + i)")
                                    .font(.system(size: 9, weight: i == 3 ? .bold : .regular))
                                    .foregroundStyle(i == 3 ? .white : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.bottom, 4)
                    // "목표" section
                    PlaceholderBar(width: 40, opacity: 0.6)
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 16, height: 16)
                        PlaceholderBar(width: 80)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(Color.orange).frame(width: 16, height: 16)
                        PlaceholderBar(width: 70)
                    }
                    // "할일" section
                    PlaceholderBar(width: 40, opacity: 0.6)
                        .padding(.top, 4)
                    HStack(spacing: 6) {
                        Image(systemName: "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        PlaceholderBar(width: 90)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        PlaceholderBar(width: 70)
                    }
                    Spacer(minLength: 0)
                }
                // 위젯 2개 stacked
                VStack(spacing: 12) {
                    // home widget small
                    IllustrationCard(width: 96, height: 96, padding: 8) {
                        HStack(spacing: 4) {
                            Text(verbatim: "18")
                                .font(.system(size: 22, weight: .bold))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                PlaceholderBar(width: 24, opacity: 0.5)
                                PlaceholderBar(width: 30, opacity: 0.5)
                            }
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Circle().fill(Color.red).frame(width: 8, height: 8)
                                PlaceholderBar(width: 48, opacity: 0.4)
                            }
                            HStack(spacing: 4) {
                                Circle().fill(Color.orange).frame(width: 8, height: 8)
                                PlaceholderBar(width: 40, opacity: 0.4)
                            }
                        }
                    }
                    // lock circular widget
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: 0.65)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "flame.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.red)
                    }
                    .frame(width: 64, height: 64)
                }
            }
        }
    }
}

// MARK: - 페이지 4: Inbox + 음성 빠른 입력

private struct OnboardingInboxPage: View {
    var body: some View {
        OnboardingFeaturePage(
            title: "onboarding.feature.inbox.title",
            subtitle: "onboarding.feature.inbox.body"
        ) {
            VStack(spacing: 20) {
                // 가벼운 list rows
                IllustrationCard(width: 280) {
                    HStack(spacing: 12) {
                        Image(systemName: "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                        PlaceholderBar(width: 140)
                        Spacer()
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                        PlaceholderBar(width: 170)
                        Spacer()
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                        PlaceholderBar(width: 120)
                        Spacer()
                    }
                }
                // QuickEntryBar 모양
                HStack(spacing: 10) {
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                        .frame(height: 36)
                        .overlay(alignment: .leading) {
                            PlaceholderBar(width: 100)
                                .padding(.leading, 14)
                        }
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                    ZStack {
                        Circle().fill(Color.accentColor)
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 44, height: 44)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(.regularMaterial)
                )
                .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
                .frame(width: 280)
            }
        }
    }
}

// MARK: - 페이지 5: 권한 안내 (실제 prompt X — 정보만)

private struct OnboardingPermissionsPage: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 20) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                Text("onboarding.title")
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 28)

            VStack(spacing: 24) {
                permissionRow(
                    icon: "bell.fill",
                    iconColor: .orange,
                    title: "onboarding.notification.title",
                    description: "onboarding.notification.body"
                )
                permissionRow(
                    icon: "heart.fill",
                    iconColor: .pink,
                    title: "onboarding.healthkit.title",
                    description: "onboarding.healthkit.body"
                )
                permissionRow(
                    icon: "mic.fill",
                    iconColor: .blue,
                    title: "onboarding.microphone.title",
                    description: "onboarding.microphone.body"
                )
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 20)

            Text("onboarding.footnote")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        iconColor: Color,
        title: LocalizedStringKey,
        description: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    OnboardingView(onContinue: {})
}
