import Foundation

/// Automation delivery plumbing: device registration and push responses.
extension APIClient {

    func registerDeviceToken(_ token: String) async throws {
        let body: Data
        do {
            body = try OttoCoding.encoder.encode(DeviceTokenRequest(token: token))
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
