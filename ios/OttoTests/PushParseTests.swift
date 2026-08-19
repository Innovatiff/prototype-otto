import UserNotifications
import XCTest

@testable import Otto

/// Pins the client half of the push contract: what counts as an automation
/// push, and which action identifiers count as answers.
final class PushParseTests: XCTestCase {

    func testParseRequiresADeliveryId() {
        let full = AutomationPush.parse(userInfo: [
            "deliveryId": "d1",
            "deepLink": "otto://brief",
            "automationType": "morning_brief",
        ])
        XCTAssertEqual(
            full,
            AutomationPush(deliveryId: "d1", deepLink: "otto://brief", automationType: "morning_brief")
        )
        // Local notifications (reminders, the guidance backstop) have no
        // deliveryId and must parse to nil so their handling is untouched.
        XCTAssertNil(AutomationPush.parse(userInfo: [:]))
        XCTAssertNil(AutomationPush.parse(userInfo: ["deliveryId": ""]))
        XCTAssertNil(AutomationPush.parse(userInfo: ["deliveryId": 42]))
    }

    func testMissingDataFieldsDegradeToEmptyStrings() {
        let bare = AutomationPush.parse(userInfo: ["deliveryId": "d1"])
        XCTAssertEqual(bare?.deepLink, "")
        XCTAssertEqual(bare?.automationType, "")
    }

    func testActionIdentifierMapping() {
        XCTAssertEqual(
            DeliveryAction.from(actionIdentifier: UNNotificationDefaultActionIdentifier),
            .opened
        )
        XCTAssertEqual(DeliveryAction.from(actionIdentifier: PushService.snoozeActionId), .snoozed)
        XCTAssertEqual(
            DeliveryAction.from(actionIdentifier: PushService.notTodayActionId),
            .dismissed
        )
        // The OS swipe-away is NOT "Not today" — reporting it would poison
        // the ignored-streak signal Step 6 reads.
        XCTAssertNil(DeliveryAction.from(actionIdentifier: UNNotificationDismissActionIdentifier))
        XCTAssertNil(DeliveryAction.from(actionIdentifier: "com.example.other"))
    }
}
