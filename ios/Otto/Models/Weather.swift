// GENERATED FROM shared/schemas — DO NOT EDIT
//
// Source: shared/schemas/weather.ts
// Regenerate with `npm run codegen`.
//
// Requires this app-target build setting:
//   SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated
//
// Under MainActor-by-default isolation these Codable conformances cannot
// compile: a main-actor-isolated initializer cannot satisfy the nonisolated
// `init(from:)` requirement.

import Foundation

struct CurrentWeather: Codable, Hashable, Sendable {
    var temperatureC: Double
    var apparentC: Double
    var precipitationMm: Double
    var precipitationProbability: Int
    var windKmh: Double
    var weatherCode: Int
    var advice: [WeatherAdvice]

    init(
        temperatureC: Double,
        apparentC: Double,
        precipitationMm: Double,
        precipitationProbability: Int,
        windKmh: Double,
        weatherCode: Int,
        advice: [WeatherAdvice]
    ) {
        self.temperatureC = temperatureC
        self.apparentC = apparentC
        self.precipitationMm = precipitationMm
        self.precipitationProbability = precipitationProbability
        self.windKmh = windKmh
        self.weatherCode = weatherCode
        self.advice = advice
    }

    private enum CodingKeys: String, CodingKey {
        case temperatureC
        case apparentC
        case precipitationMm
        case precipitationProbability
        case windKmh
        case weatherCode
        case advice
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.temperatureC = try container.decode(Double.self, forKey: .temperatureC)
        self.apparentC = try container.decode(Double.self, forKey: .apparentC)
        self.precipitationMm = try container.decode(Double.self, forKey: .precipitationMm)
        self.precipitationProbability = try container.decode(Int.self, forKey: .precipitationProbability)
        self.windKmh = try container.decode(Double.self, forKey: .windKmh)
        self.weatherCode = try container.decode(Int.self, forKey: .weatherCode)
        self.advice = try container.decode([WeatherAdvice].self, forKey: .advice)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.temperatureC, forKey: .temperatureC)
        try container.encode(self.apparentC, forKey: .apparentC)
        try container.encode(self.precipitationMm, forKey: .precipitationMm)
        try container.encode(self.precipitationProbability, forKey: .precipitationProbability)
        try container.encode(self.windKmh, forKey: .windKmh)
        try container.encode(self.weatherCode, forKey: .weatherCode)
        try container.encode(self.advice, forKey: .advice)
    }
}

struct HourlyForecast: Codable, Hashable, Sendable {
    var at: Date
    var temperatureC: Double
    var apparentC: Double
    var precipitationProbability: Int
    var precipitationMm: Double
    var windKmh: Double
    var weatherCode: Int

    init(
        at: Date,
        temperatureC: Double,
        apparentC: Double,
        precipitationProbability: Int,
        precipitationMm: Double,
        windKmh: Double,
        weatherCode: Int
    ) {
        self.at = at
        self.temperatureC = temperatureC
        self.apparentC = apparentC
        self.precipitationProbability = precipitationProbability
        self.precipitationMm = precipitationMm
        self.windKmh = windKmh
        self.weatherCode = weatherCode
    }

    private enum CodingKeys: String, CodingKey {
        case at
        case temperatureC
        case apparentC
        case precipitationProbability
        case precipitationMm
        case windKmh
        case weatherCode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.at = try container.decode(Date.self, forKey: .at)
        self.temperatureC = try container.decode(Double.self, forKey: .temperatureC)
        self.apparentC = try container.decode(Double.self, forKey: .apparentC)
        self.precipitationProbability = try container.decode(Int.self, forKey: .precipitationProbability)
        self.precipitationMm = try container.decode(Double.self, forKey: .precipitationMm)
        self.windKmh = try container.decode(Double.self, forKey: .windKmh)
        self.weatherCode = try container.decode(Int.self, forKey: .weatherCode)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.at, forKey: .at)
        try container.encode(self.temperatureC, forKey: .temperatureC)
        try container.encode(self.apparentC, forKey: .apparentC)
        try container.encode(self.precipitationProbability, forKey: .precipitationProbability)
        try container.encode(self.precipitationMm, forKey: .precipitationMm)
        try container.encode(self.windKmh, forKey: .windKmh)
        try container.encode(self.weatherCode, forKey: .weatherCode)
    }
}

enum WeatherAdvice: String, Codable, Hashable, Sendable, CaseIterable {
    case rain
    case cold
    case wind
}
