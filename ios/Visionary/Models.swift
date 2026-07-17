import Foundation

// All wire types decode/encode through the shared snake_case coders in APIClient
// (e.g. "two_way" <-> twoWay, "interval_s" <-> intervalS, "image_path" <-> imagePath).

struct DeviceStatus: Decodable {
    let online: Bool
    let battery: Double?    // always null in v1 hardware; UI shows a dash
    let wifi: String?
    let version: String
    let uptime: Double
    let busy: Bool
    let recording: Bool
}

struct TwoWayConfig: Codable, Equatable {
    var enabled: Bool
    var theirs: String
    var yours: String
}

struct WakeWordConfig: Codable, Equatable {
    var enabled: Bool
    var model: String
}

struct NavigationConfig: Codable, Equatable {
    var enabled: Bool
    var intervalS: Double
}

struct DeviceConfig: Codable, Equatable {
    var voice: String
    var rate: Double
    var language: String?
    var twoWay: TwoWayConfig
    var gestures: [String: String]
    var features: [String: Bool]
    var wakeWord: WakeWordConfig
    var navigation: NavigationConfig

    enum CodingKeys: String, CodingKey {
        case voice, rate, language, twoWay, gestures, features, wakeWord, navigation
    }

    // Custom encode so clearing `language` sends an explicit null: PUT /config
    // deep-merges, and synthesized Codable would omit the key, silently keeping
    // the old translation target on the device.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(voice, forKey: .voice)
        try c.encode(rate, forKey: .rate)
        if let language = language {
            try c.encode(language, forKey: .language)
        } else {
            try c.encodeNil(forKey: .language)
        }
        try c.encode(twoWay, forKey: .twoWay)
        try c.encode(gestures, forKey: .gestures)
        try c.encode(features, forKey: .features)
        try c.encode(wakeWord, forKey: .wakeWord)
        try c.encode(navigation, forKey: .navigation)
    }
}

struct HistoryEntry: Decodable, Identifiable, Equatable {
    let id: Int
    let ts: Double
    let kind: String        // read | describe | ask | recording | translate
    let text: String
    let extra: [String: String]?
    let imagePath: String?  // presence flag only; bytes come from APIClient.image(id:)
    let audioPath: String?  // presence flag only; bytes come from /history/{id}/audio

    var hasImage: Bool { imagePath != nil }
    var hasAudio: Bool { audioPath != nil }
}

struct HistoryPage: Decodable {
    let entries: [HistoryEntry]
    let page: Int
    let perPage: Int
    let total: Int
}

/// One /memory/search result. The wire shape is a flat history-entry dict plus
/// a "score" field, so the entry decodes from the same container as the score.
struct MemoryHit: Decodable, Identifiable, Equatable {
    let entry: HistoryEntry
    let score: Double

    var id: Int { entry.id }

    private enum CodingKeys: String, CodingKey { case score }

    init(from decoder: Decoder) throws {
        entry = try HistoryEntry(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
    }
}

/// Queued Tier 3 phone action minted by the glasses' tool-use loop.
/// type ∈ calendar_event | reminder. Payload values are always strings —
/// calendar_event: {"title", "date" (ISO8601), "notes"?}; reminder: {"title", "notes"?}.
struct PhoneAction: Decodable, Identifiable, Equatable {
    let id: Int
    let ts: Double
    let type: String
    let payload: [String: String]
    let status: String      // pending | done | failed
}

// QR payload and manual-entry pairing shape: {"url": "...", "token": "123456"}
struct PairingPayload: Codable, Equatable {
    let url: String
    let token: String
}
