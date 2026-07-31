import Foundation

/// Identifiable conformances for generated models (they already carry `id`
/// fields; the generator deliberately emits only Codable/Hashable/Sendable).
/// Lives outside Models/ — generated files are never hand-edited, but
/// extending them here is fine and survives regeneration.
extension Memory: Identifiable {}
extension OttoTask: Identifiable {}
extension ListItem: Identifiable {}
