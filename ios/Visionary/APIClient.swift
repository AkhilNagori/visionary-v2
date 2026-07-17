import Foundation
import UIKit

enum APIError: Error, LocalizedError {
    case unauthorized
    case http(Int)
    case transport(Error)
    case decoding

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "The glasses rejected the pairing token. Re-pair from the Pairing screen."
        case .http(let code):
            return code == 409 ? "The glasses are busy. Try again in a moment."
                               : "The glasses returned an error (HTTP \(code))."
        case .transport:
            return "Couldn't reach the glasses. Make sure your phone and the glasses share a network."
        case .decoding:
            return "The glasses sent an unexpected response."
        }
    }
}

final class APIClient {
    let baseURL: URL
    let token: String

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    // MARK: - Endpoints

    func status() async throws -> DeviceStatus {
        try await getJSON("status")
    }

    func getConfig() async throws -> DeviceConfig {
        try await getJSON("config")
    }

    func putConfig(_ config: DeviceConfig) async throws -> DeviceConfig {
        let body: Data
        do { body = try Self.encoder.encode(config) } catch { throw APIError.decoding }
        let data = try await send(request("config", method: "PUT", body: body))
        return try decode(data)
    }

    func history(page: Int = 1, perPage: Int = 20) async throws -> HistoryPage {
        try await getJSON("history", query: [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage)),
        ])
    }

    func image(id: Int) async throws -> UIImage? {
        do {
            let data = try await send(request("history/\(id)/image"))
            return UIImage(data: data)
        } catch APIError.http(404) {
            return nil
        }
    }

    func capture(mode: String) async throws {
        _ = try await send(request("capture", method: "POST", body: encodeBody(["mode": mode])))
    }

    func speak(_ text: String) async throws {
        _ = try await send(request("speak", method: "POST", body: encodeBody(["text": text])))
    }

    func wifi(ssid: String, psk: String) async throws {
        _ = try await send(request("wifi", method: "POST", body: encodeBody(["ssid": ssid, "psk": psk])))
    }

    func update() async throws {
        _ = try await send(request("update", method: "POST"))
    }

    func liveRequest() -> URLRequest {
        var r = request("live")
        r.timeoutInterval = 86_400   // MJPEG stream stays open indefinitely
        return r
    }

    func audioRequest(id: Int) -> URLRequest {
        request("history/\(id)/audio")
    }

    func memorySearch(_ query: String, k: Int = 5) async throws -> [MemoryHit] {
        struct Results: Decodable { let results: [MemoryHit] }
        let wrapper: Results = try await getJSON("memory/search", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "k", value: String(k)),
        ])
        return wrapper.results
    }

    func pendingActions() async throws -> [PhoneAction] {
        struct Actions: Decodable { let actions: [PhoneAction] }
        let wrapper: Actions = try await getJSON("actions")
        return wrapper.actions
    }

    func completeAction(id: Int, status: String, result: String) async throws {
        _ = try await send(request("actions/\(id)", method: "POST",
                                   body: encodeBody(["status": status, "result": result])))
    }

    // MARK: - v3: modes & packs

    /// GET /modes → {"modes": [Mode...], "active_mode": id|null}.
    func modes() async throws -> (modes: [Mode], activeMode: String?) {
        struct Response: Decodable {
            let modes: [Mode]
            let activeMode: String?
        }
        let r: Response = try await getJSON("modes")
        return (r.modes, r.activeMode)
    }

    /// POST /modes/active {"id": "..."} — nil sends an explicit null,
    /// which returns the glasses to classic single-press reading.
    func setActiveMode(_ id: String?) async throws {
        struct Body: Encodable {
            let id: String?
            enum CodingKeys: String, CodingKey { case id }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                if let id = id { try c.encode(id, forKey: .id) }
                else { try c.encodeNil(forKey: .id) }
            }
        }
        _ = try await send(request("modes/active", method: "POST", body: encodeBody(Body(id: id))))
    }

    func packs() async throws -> [Pack] {
        struct Response: Decodable { let packs: [Pack] }
        let wrapper: Response = try await getJSON("packs")
        return wrapper.packs
    }

    /// POST /packs/install {"url"} → the ids of the newly installed modes.
    @discardableResult
    func installPack(url: String) async throws -> [String] {
        struct Response: Decodable {
            let modes: [String]?
            let installed: [String]?
        }
        let data = try await send(request("packs/install", method: "POST",
                                          body: encodeBody(["url": url])))
        let r = try? Self.decoder.decode(Response.self, from: data)
        return r?.modes ?? r?.installed ?? []
    }

    func removePack(name: String) async throws {
        _ = try await send(request("packs/\(name)", method: "DELETE"))
    }

    // MARK: - v3: flashcards

    /// POST /flashcards/generate → number of cards minted from today's history.
    @discardableResult
    func flashcardsGenerate() async throws -> Int {
        struct Response: Decodable {
            let created: Int?
            let count: Int?
            let cards: [Flashcard]?
        }
        let data = try await send(request("flashcards/generate", method: "POST"))
        let r = try? Self.decoder.decode(Response.self, from: data)
        return r?.created ?? r?.count ?? r?.cards?.count ?? 0
    }

    func flashcardsDue() async throws -> [Flashcard] {
        struct Response: Decodable { let cards: [Flashcard] }
        let wrapper: Response = try await getJSON("flashcards/due")
        return wrapper.cards
    }

    /// grade ∈ 0...3 (again / hard / good / easy).
    func reviewFlashcard(id: Int, grade: Int) async throws {
        _ = try await send(request("flashcards/\(id)/review", method: "POST",
                                   body: encodeBody(["grade": grade])))
    }

    // MARK: - v3: listen, timers, events

    /// POST /listen — the glasses record until silence (or maxS) and return
    /// the transcript. Blocks for the whole capture, so the timeout stretches.
    func listen(maxS: Double = 15) async throws -> String {
        struct Response: Decodable { let text: String }
        var r = request("listen", method: "POST", body: encodeBody(["max_s": maxS]))
        r.timeoutInterval = maxS + 60
        let wrapper: Response = try decode(try await send(r))
        return wrapper.text
    }

    func timers() async throws -> [DeviceTimer] {
        struct Response: Decodable { let timers: [DeviceTimer] }
        let wrapper: Response = try await getJSON("timers")
        return wrapper.timers
    }

    /// GET /events — a text/event-stream request for EventSource to hold open.
    func eventsRequest() -> URLRequest {
        var r = request("events")
        r.timeoutInterval = 86_400
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return r
    }

    // MARK: - Plumbing

    private func request(_ path: String, method: String = "GET",
                         body: Data? = nil, query: [URLQueryItem]? = nil) -> URLRequest {
        var url = baseURL.appendingPathComponent(path)
        if let query = query,
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = query
            url = comps.url ?? url
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body = body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.decoding }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw APIError.unauthorized
        default: throw APIError.http(http.statusCode)
        }
    }

    private func getJSON<T: Decodable>(_ path: String, query: [URLQueryItem]? = nil) async throws -> T {
        try decode(try await send(request(path, query: query)))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding }
    }

    private func encodeBody<T: Encodable>(_ value: T) -> Data? {
        try? Self.encoder.encode(value)
    }
}
