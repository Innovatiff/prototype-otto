import Foundation

/// Automation delivery plumbing: device registration and push responses —
/// plus the management screen's list/update/delete/settings calls.
extension APIClient {

    func listAutomations() async throws -> AutomationListResponse {
        let data = try await jsonRequest(path: "automations", method: "GET")
        return try decodeBody(AutomationListResponse.self, from: data)
    }

    func updateAutomation(id: String, enabled: Bool?, timeOfDay: String?) async throws {
        let body: Data
        do {
            body = try OttoCoding.encoder.encode(
                AutomationUpdateRequest(enabled: enabled, timeOfDay: timeOfDay)
            )
        } catch {
            throw APIError.decoding(underlying: error)
        }
        _ = try await jsonRequest(path: "automations/\(id)/update", method: "POST", body: body)
    }

    func deleteAutomation(id: String) async throws {
        _ = try await jsonRequest(path: "automations/\(id)", method: "DELETE")
    }

    func updateAutomationSettings(quietHoursStart: String, quietHoursEnd: String) async throws {
        let body: Data
        do {
            body = try OttoCoding.encoder.encode(
                AutomationSettingsRequest(
                    quietHoursStart: quietHoursStart,
                    quietHoursEnd: quietHoursEnd
                )
            )
        } catch {
            throw APIError.decoding(underlying: error)
        }
        _ = try await jsonRequest(path: "automations/settings", method: "POST", body: body)
    }

    func registerDeviceToken(_ token: String) async throws {
        let body: Data
        do {
            // The timezone rides along so the server can seed the built-in
            // automations the moment pushes become deliverable.
            body = try OttoCoding.encoder.encode(
                DeviceTokenRequest(token: token, timezone: TimeZone.current.identifier)
            )
        } catch {
            throw APIError.decoding(underlying: error)
        }
        _ = try await jsonRequest(path: "automations/devices", method: "POST", body: body)
    }

    func reportDeliveryResponse(deliveryId: String, action: DeliveryAction) async throws {
        let body: Data
        do {
            body = try OttoCoding.encoder.encode(
                DeliveryResponseRequest(deliveryId: deliveryId, action: action)
            )
        } catch {
            throw APIError.decoding(underlying: error)
        }
        _ = try await jsonRequest(path: "automations/response", method: "POST", body: body)
    }
}
