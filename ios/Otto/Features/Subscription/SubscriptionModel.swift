import Foundation
import Observation
import RevenueCat
import UserNotifications

/// The client's view of the subscription — cosmetic by design. RevenueCat
/// reports entitlements here so UI can hide and paywalls can price; the
/// SERVER (fed by the RevenueCat webhook) makes every gating decision.
enum SubscriptionTier: String {
    case free, lite, pro, max
}

struct SubscriptionState {
    var tier: SubscriptionTier = .free
    var isInTrial = false
    var expiresAt: Date?
    var willRenew = false
    var seatsUsed = 0
}

@MainActor
@Observable
final class SubscriptionModel {

    private(set) var state = SubscriptionState()
    private(set) var offerings: Offerings?
    /// False until a real API key is configured — the paywall says so
    /// instead of pretending.
    private(set) var purchasesAvailable = false
    var errorMessage: String?

    private var configured = false
    private static let trialReminderId = "otto.trial.reminder"
    private let auth: any AuthProvider

    init(auth: any AuthProvider) {
        self.auth = auth
    }

    /// Call freely (launch, sign-in): configures once, then keeps the
    /// RevenueCat identity aligned with the Firebase uid.
    func configureIfNeeded() {
        configure(appUserID: auth.currentUserId)
    }

    /// Reads the public SDK key from Info.plist (REVENUECAT_API_KEY). The
    /// placeholder value leaves purchases disabled gracefully.
    private func configure(appUserID: String?) {
        guard !configured else {
            if let appUserID {
                Task { _ = try? await Purchases.shared.logIn(appUserID) }
            }
            return
        }
        let key = Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_API_KEY") as? String ?? ""
        guard !key.isEmpty, !key.hasPrefix("YOUR_") else { return }
        Purchases.configure(withAPIKey: key, appUserID: appUserID)
        configured = true
        purchasesAvailable = true
        Task { await self.refresh() }
        Task { await self.watchCustomerInfo() }
    }

    func refresh() async {
        guard configured else { return }
        do {
            offerings = try await Purchases.shared.offerings()
            apply(try await Purchases.shared.customerInfo())
            errorMessage = nil
        } catch {
            errorMessage = "Store unavailable: \(error.localizedDescription)"
        }
    }

    func purchase(_ package: Package) async -> Bool {
        guard configured else { return false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            apply(result.customerInfo)
            return !result.userCancelled
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Required by Apple: restores entitlements on a fresh install.
    func restorePurchases() async {
        guard configured else { return }
        do {
            apply(try await Purchases.shared.restorePurchases())
            errorMessage = nil
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func watchCustomerInfo() async {
        for await info in Purchases.shared.customerInfoStream {
            apply(info)
        }
    }

    private func apply(_ info: CustomerInfo) {
        let active = info.entitlements.active
        let entitlement = active["max"] ?? active["pro"] ?? active["lite"]
        var next = SubscriptionState()
        if let entitlement {
            next.tier =
                active["max"] != nil ? .max : active["pro"] != nil ? .pro : .lite
            next.isInTrial = entitlement.periodType == .trial
            next.expiresAt = entitlement.expirationDate
            next.willRenew = entitlement.willRenew
        }
        state = next
        scheduleTrialReminder()
    }

    /// Trial expiring in 2 days: ONE local notification, not a campaign.
    /// The fixed identifier means re-scheduling replaces, never stacks.
    private func scheduleTrialReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.trialReminderId])
        guard state.isInTrial, let expiresAt = state.expiresAt else { return }
        let fireAt = expiresAt.addingTimeInterval(-2 * 24 * 3600)
        guard fireAt.timeIntervalSinceNow > 60 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your Otto trial ends in two days"
        content.body = "Keep the morning brief, plans, and voyages — or cancel anytime in Settings."
        content.sound = nil
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: fireAt.timeIntervalSinceNow, repeats: false
        )
        center.add(
            UNNotificationRequest(identifier: Self.trialReminderId, content: content, trigger: trigger)
        )
    }

    // MARK: - Paywall helpers

    /// Packages for a tier + cadence, matched by product identifier
    /// convention (…lite/pro/max…monthly/annual). Prices always come from
    /// the store, never hardcoded.
    func package(tier: SubscriptionTier, annual: Bool) -> Package? {
        let packages = offerings?.current?.availablePackages ?? []
        return packages.first { package in
            let id = package.storeProduct.productIdentifier.lowercased()
            return id.contains(tier.rawValue) && id.contains(annual ? "annual" : "monthly")
        }
    }

    /// "$29.99/mo" etc., straight from StoreKit.
    static func priceLine(_ package: Package, annual: Bool) -> String {
        "\(package.storeProduct.localizedPriceString)/\(annual ? "yr" : "mo")"
    }

    /// Whole-percent savings of annual vs 12× monthly, when both exist.
    func annualSavingsPercent(tier: SubscriptionTier) -> Int? {
        guard
            let monthly = package(tier: tier, annual: false),
            let annual = package(tier: tier, annual: true)
        else { return nil }
        let monthlyYear = monthly.storeProduct.price * 12
        let annualPrice = annual.storeProduct.price
        guard monthlyYear > 0, annualPrice < monthlyYear else { return nil }
        let fraction = (monthlyYear - annualPrice) / monthlyYear
        return Int((NSDecimalNumber(decimal: fraction).doubleValue * 100).rounded())
    }
}
