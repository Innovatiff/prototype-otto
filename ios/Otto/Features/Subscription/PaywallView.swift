import RevenueCat
import StoreKit
import SwiftUI

/// What a contextual paywall is about — a gated feature names itself and
/// the headline speaks to THAT, never a generic grid.
struct PaywallContext: Identifiable {
    let feature: String
    let requiredTier: String
    var id: String { feature }

    var headline: String {
        switch feature {
        case "experiences": return "Trip and date planning is part of Pro"
        case "plans": return "You've used this month's plans"
        case "custom_automations": return "More automations come with Pro"
        case "seats": return "Family seats come with Max"
        default: return "This is part of Otto Pro"
        }
    }

    var subline: String {
        switch feature {
        case "experiences":
            return "Researched itineraries with real places, budgets kept under, saved to Voyages."
        case "plans":
            return "Higher tiers raise the monthly plan allowance — everything you've made stays."
        case "custom_automations":
            return "Lite includes three custom automations; Pro removes the cap."
        default:
            return "A coach, a planner, and an assistant. One subscription."
        }
    }
}

/// The paywall: three tiers, Pro preselected, annual default with savings,
/// trial terms in plain words, Restore/Terms/Privacy visible, and always
/// dismissable — the app stays usable in its free state.
struct PaywallView: View {
    @Bindable var model: SubscriptionModel
    var context: PaywallContext?
    var onDismiss: () -> Void

    @State private var selectedTier: SubscriptionTier = .pro
    @State private var annual = true
    @State private var purchasing = false

    private static let termsURL = URL(string: "https://ottoassistant.app/terms")!
    private static let privacyURL = URL(string: "https://ottoassistant.app/privacy")!
    private static let manageURL = URL(string: "itms-apps://apps.apple.com/account/subscriptions")!

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                cadenceToggle
                tierCards
                purchaseButton
                trialTerms
                footerLinks
            }
            .padding(20)
        }
        .background(OttoTheme.background.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OttoTheme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(OttoTheme.control, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(14)
            .accessibilityLabel("Not now")
        }
        .task { await model.refresh() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(OttoTheme.peach)
                .padding(.top, 26)
            Text(context?.headline ?? "A coach, a planner, and an assistant.")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(OttoTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text(context?.subline ?? "One subscription. Everything Otto does, all day.")
                .font(.subheadline)
                .foregroundStyle(OttoTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var cadenceToggle: some View {
        Picker("Billing", selection: $annual) {
            Text("Annual").tag(true)
            Text("Monthly").tag(false)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
    }

    private var tierCards: some View {
        VStack(spacing: 10) {
            tierCard(.lite, title: "Lite", blurb: "The daily assistant: briefs, plans, walkthroughs, automations.")
            tierCard(.pro, title: "Pro", blurb: "Everything, for your whole life: experiences & Voyages, premium voice, all domains.")
            tierCard(.max, title: "Max", blurb: "Pro for the household: 3 family seats, 50 plans, priority.")
        }
    }

    private func tierCard(_ tier: SubscriptionTier, title: String, blurb: String) -> some View {
        let package = model.package(tier: tier, annual: annual)
        let selected = selectedTier == tier
        return Button {
            Haptics.tick()
            selectedTier = tier
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(OttoTheme.textPrimary)
                        if tier == .pro {
                            Text("POPULAR")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(OttoTheme.peach, in: Capsule())
                        }
                        if annual, let savings = model.annualSavingsPercent(tier: tier) {
                            Text("SAVE \(savings)%")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(OttoTheme.mint)
                        }
                    }
                    Text(blurb)
                        .font(.caption)
                        .foregroundStyle(OttoTheme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Text(package.map { SubscriptionModel.priceLine($0, annual: annual) } ?? "—")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(OttoTheme.textPrimary)
            }
            .padding(14)
            .background(OttoTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(selected ? OttoTheme.ink : OttoTheme.hairline, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var purchaseButton: some View {
        Button {
            guard let package = model.package(tier: selectedTier, annual: annual) else { return }
            purchasing = true
            Task {
                let bought = await model.purchase(package)
                purchasing = false
                if bought { onDismiss() }
            }
        } label: {
            Group {
                if purchasing {
                    ProgressView().tint(.white)
                } else {
                    Text(selectedTier == .pro ? "Start 7 days free" : "Continue")
                        .font(.callout.weight(.semibold))
                }
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(OttoTheme.ink, in: Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .disabled(purchasing || !model.purchasesAvailable)
    }

    private var trialTerms: some View {
        VStack(spacing: 4) {
            if !model.purchasesAvailable {
                Text("Purchases are not available in this build yet.")
                    .font(.caption)
                    .foregroundStyle(OttoTheme.textTertiary)
            } else if let package = model.package(tier: selectedTier, annual: annual) {
                // Price, duration, and renewal terms — visible, plain.
                Text(
                    (selectedTier == .pro ? "7 days free, then " : "")
                        + "\(package.storeProduct.localizedPriceString) per "
                        + (annual ? "year" : "month")
                        + ", auto-renews. Cancel anytime."
                )
                .font(.caption)
                .foregroundStyle(OttoTheme.textSecondary)
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var footerLinks: some View {
        VStack(spacing: 10) {
            Button("Restore Purchases") {
                Task { await model.restorePurchases() }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(OttoTheme.textPrimary)
            HStack(spacing: 16) {
                Link("Terms", destination: Self.termsURL)
                Link("Privacy", destination: Self.privacyURL)
                Link("Manage subscription", destination: Self.manageURL)
            }
            .font(.caption)
            .foregroundStyle(OttoTheme.textSecondary)
        }
        .padding(.bottom, 20)
    }
}
