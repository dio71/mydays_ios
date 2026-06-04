import SwiftUI

// MARK: - PaywallView
//
// 프로 플랜 안내/구매 화면. 잠긴 기능(cap 초과 / 테마 색상 / 활동 보고서) 진입 시
// alert의 "프로 플랜으로 업그레이드하기" 버튼 → 이 화면을 sheet로 표시.
//
// 진입점 3종 공용: Settings 상시 entry / cap 도달 / 기능 진입.
//
// ⚠️ 현재 StoreKit 2 미연결 — 구매/복원 버튼은 테스트용으로 즉시 언락(@AppStorage).
//    실제 결제 연결 시 purchase()/restore() 내부만 교체.

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss

    // 테스트용 언락 — StoreKit 연결 전까지 구매/복원이 이 값을 set.
    @AppStorage(PremiumKey.isUnlocked, store: .appShared) private var premiumUnlocked = false

    @State private var showPrivacyPolicy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    benefits
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)
            }
            .safeAreaInset(edge: .bottom) { footer }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                    .tint(.secondary)
                }
            }
            .sheet(isPresented: $showPrivacyPolicy) {
                SafariView(url: AppLinks.privacyPolicy)
                    .ignoresSafeArea()
            }
        }
        .appTint()
    }

    // MARK: 헤더

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.system(size: 46))
                .foregroundStyle(Color.accentColor)
            Text("paywall.title")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("paywall.subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: 혜택 리스트

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 16) {
            benefitRow("paywall.benefit.unlimited")
            benefitRow("paywall.benefit.themes")
            benefitRow("paywall.benefit.reports")
            benefitRow("paywall.benefit.future")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func benefitRow(_ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text(key)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: 하단 구매 영역

    private var footer: some View {
        VStack(spacing: 12) {
            if premiumUnlocked {
                Label("paywall.already", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .padding(.vertical, 10)
            } else {
                Button {
                    purchase()
                } label: {
                    Text("paywall.purchase")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)

                // 가격은 출시 시 App Store Connect에서 확정 → StoreKit이 실제 가격 표시 예정.
                Text("paywall.price.placeholder")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("paywall.restore") { restore() }
                    .font(.subheadline)
            }

            Button("settings.privacy_policy") { showPrivacyPolicy = true }
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.bar)
    }

    // MARK: 액션 (StoreKit 연결 시 내부만 교체)

    private func purchase() {
        // TODO: StoreKit 2 — Product.purchase() + transaction 검증 후 언락.
        premiumUnlocked = true
        dismiss()
    }

    private func restore() {
        // TODO: StoreKit 2 — AppStore.sync() / 현재 entitlement 확인 후 언락.
        premiumUnlocked = true
        dismiss()
    }
}

#Preview {
    PaywallView()
}
