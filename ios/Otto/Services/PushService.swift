import FirebaseMessaging
import Foundation
import UIKit
import UserNotifications

/// One automation push, as parsed from a notification's userInfo. The
/// server puts these three strings in the FCM data payload.
struct AutomationPush: Equatable, Sendable {
    let deliveryId: String
    let deepLink: String
    let automationType: String

    /// Nil for anything that is not an automation push (local reminders,
    /// the guidance backstop) — those keep their existing handling.
    nonisolated static func parse(userInfo: [AnyHashable: Any]) -> AutomationPush? {
        guard let deliveryId = userInfo["deliveryId"] as? String, !deliveryId.isEmpty else {
            return nil
        }
        return AutomationPush(
            deliveryId: deliveryId,
            deepLink: (userInfo["deepLink"] as? String) ?? "",
            automationType: (userInfo["automationType"] as? String) ?? ""
        )
    }
}

extension DeliveryAction {
    /// The user's answer, from the response's action identifier. Nil for
    /// the OS swipe-away — clearing a notification is not "Not today",
    /// and reporting it would poison the ignored-streak signal.
    nonisolated static func from(actionIdentifier: String) -> DeliveryAction? {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            return .opened
        case PushService.snoozeActionId:
            return .snoozed
        case PushService.notTodayActionId:
            return .dismissed
        default:
            return nil
        }
    }
}

/// FCM plumbing: registers the device, keeps the server's token fresh, and
/// reports how the user answered each push. Content policy lives entirely
/// server-side — this class never composes anything.
@MainActor
final class PushService: NSObject {

    nonisolated static let categoryId = "OTTO_AUTOMATION"
    nonisolated static let snoozeActionId = "OTTO_SNOOZE"
    nonisolated static let notTodayActionId = "OTTO_NOT_TODAY"
    /// The token the server currently has, so re-uploads are skipped.
    static let uploadedTokenKey = "otto.push.uploadedToken"

    private let auth: any AuthProvider
    private var latestToken: String?

    init(auth: any AuthProvider) {
        self.auth = auth
        super.init()
    }

    /// Called once from the root view's activation: registers the action
    /// category, starts APNs registration (token issuance needs no user
    /// permission; visible alerts are gated by the existing notification
    /// authorization flows), and asks FCM for the current token.
    func start() {
        let snooze = UNNotificationAction(identifier: Self.snoozeActionId, title: "Snooze 30 min")
        let notToday = UNNotificationAction(identifier: Self.notTodayActionId, title: "Not today")
        let category = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [snooze, notToday],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])

        Messaging.messaging().delegate = self
        UIApplication.shared.registerForRemoteNotifications()
        Messaging.messaging().token { [weak self] token, _ in
            guard let token else { return }
            Task { @MainActor in
                self?.latestToken = token
                await self?.uploadTokenIfNeeded()
            }
        }
    }

    /// Uploads the token when there is one, a signed-in user, and the
    /// server doesn't already have it. Safe to call often.
    func uploadTokenIfNeeded() async {
        guard let token = latestToken, auth.currentUserId != nil else { return }
        guard UserDefaults.standard.string(forKey: Self.uploadedTokenKey) != token else { return }
        guard let client = makeClient() else { return }
        do {
            try await client.registerDeviceToken(token)
            UserDefaults.standard.set(token, forKey: Self.uploadedTokenKey)
        } catch {
            // Silent; retried on the next foreground/token refresh.
        }
    }

    /// Reports opened / snoozed / dismissed. Best-effort — losing one
    /// report costs a little engagement signal, never a feature.
    func report(_ push: AutomationPush, action: DeliveryAction) async {
        guard let client = makeClient() else { return }
        try? await client.reportDeliveryResponse(deliveryId: push.deliveryId, action: action)
    }

    private func makeClient() -> APIClient? {
        let urlString =
            UserDefaults.standard.string(forKey: DebugModel.serverURLKey) ?? "http://localhost:8080"
        guard let url = URL(string: urlString), url.scheme != nil else { return nil }
        guard auth.currentUserId != nil else { return nil }
        return APIClient(baseURL: url, auth: auth)
    }
}

extension PushService: MessagingDelegate {
    /// FCM rotates tokens (reinstall, restore, key rotation); every
    /// rotation re-uploads.
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        Task { @MainActor in
            self.latestToken = fcmToken
            await self.uploadTokenIfNeeded()
        }
    }
}
