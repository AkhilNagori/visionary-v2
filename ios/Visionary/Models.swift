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

// MARK: - v3 mode-pack platform

/// One installable "app": a crafted prompt on a shared pipeline.
/// pipeline ∈ see | ask | listen | loop | session. The wire dict also carries
/// an untyped "options" object the app doesn't need, so it isn't modeled.
struct Mode: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let category: String
    let description: String
    let pipeline: String
    let prompt: String

    private enum CodingKeys: String, CodingKey {
        case id, name, category, description, pipeline, prompt
    }

    // Lenient on the descriptive fields so one sloppy community pack can't
    // take down the whole Modes tab; id/name/pipeline stay required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        pipeline = try c.decode(String.self, forKey: .pipeline)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "other"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    }
}

/// One installed pack from GET /packs: {"name", "builtin": bool, "modes": [ids]}.
struct Pack: Decodable, Identifiable, Equatable {
    let name: String
    let builtin: Bool
    let modes: [String]

    var id: String { name }
}

/// One spaced-repetition card from /flashcards/due. `due` and `ts` are unix
/// timestamps; `intervalD` is the current interval in days ("interval_d").
/// Scheduling fields are optional so a leaner server payload still decodes.
struct Flashcard: Decodable, Identifiable, Equatable {
    let id: Int
    let ts: Double?
    let question: String
    let answer: String
    let due: Double?
    let intervalD: Double?
    let ease: Double?
}

/// One event from the glasses' /events SSE stream. On the wire `data` is a
/// bare string for captions and may be an object for other kinds, so both
/// shapes land in `text`. `seq` is rewritten by EventSource to be unique and
/// strictly increasing even when the device restarts its ring buffer.
struct DeviceEvent: Decodable, Identifiable, Equatable {
    var seq: Int
    let ts: Double
    let kind: String
    let text: String

    var id: Int { seq }

    private enum CodingKeys: String, CodingKey { case seq, ts, kind, data, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? -1
        ts = try c.decodeIfPresent(Double.self, forKey: .ts) ?? Date().timeIntervalSince1970
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "event"
        if let s = try? c.decode(String.self, forKey: .data) {
            text = s
        } else if let dict = try? c.decode([String: String].self, forKey: .data) {
            text = dict["text"] ?? dict["phrase"] ?? dict["message"]
                ?? dict.values.sorted().joined(separator: " ")
        } else if let s = try? c.decode(String.self, forKey: .text) {
            text = s
        } else {
            text = ""
        }
    }

    init(seq: Int, ts: Double, kind: String, text: String) {
        self.seq = seq
        self.ts = ts
        self.kind = kind
        self.text = text
    }
}

/// One named kitchen timer from GET /timers. The firmware may report either
/// seconds remaining ("remaining_s") or an absolute end time ("ends_at").
struct DeviceTimer: Decodable, Identifiable, Equatable {
    let name: String
    let remainingS: Double?
    let endsAt: Double?

    var id: String { name }

    var secondsLeft: Double? {
        if let remaining = remainingS { return max(0, remaining) }
        if let end = endsAt { return max(0, end - Date().timeIntervalSince1970) }
        return nil
    }
}
