import Foundation

// All wire types decode/encode through the shared snake_case coders in APIClient
// (e.g. "two_way" <-> twoWay, "image_path" <-> imagePath).

struct DeviceStatus: Decodable {
    let online: Bool
    let battery: Double?    // always null in v1 hardware; UI shows an em-less dash
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

struct DeviceConfig: Codable, Equatable {
    var voice: String
    var rate: Double
    var language: String?
    var twoWay: TwoWayConfig
    var gestures: [String: String]
    var features: [String: Bool]

    enum CodingKeys: String, CodingKey {
        case voice, rate, language, twoWay, gestures, features
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

// QR payload and manual-entry pairing shape: {"url": "...", "token": "123456"}
struct PairingPayload: Codable, Equatable {
    let url: String
    let token: String
}
