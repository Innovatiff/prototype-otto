import Foundation

/// Re-decodes a TurnEvent's loosely typed payload into a concrete generated
/// model: the JSONValue re-encodes to canonical JSON bytes, which the shared
/// decoder (ISO dates and all) then parses. Lives outside Models/ because
/// generated files are never hand-edited.
extension JSONValue {
    func decoded<T: Decodable>(as type: T.Type) -> T? {
        guard let data = try? OttoCoding.encoder.encode(self) else { return nil }
        return try? OttoCoding.decoder.decode(type, from: data)
    }
}
