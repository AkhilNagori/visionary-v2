import Foundation

/// Client for the glasses' `GET /events` Server-Sent-Events stream.
///
/// URLSession has no native SSE support, so this parses the text/event-stream
/// body off a data-task delegate by hand: `data:` lines accumulate until a
/// blank line dispatches one event, whose JSON payload decodes as a
/// `DeviceEvent`. Dropped connections reconnect automatically with exponential
/// backoff (1s doubling to a 15s cap, reset once a stream opens) until
/// `stop()` is called. All @Published mutation happens on the main queue.
final class EventSource: NSObject, ObservableObject, URLSessionDataDelegate {

    enum ConnectionState: Equatable {
        case idle            // never started, or stopped
        case connecting
        case open
        case waitingToRetry
    }

    @Published private(set) var events: [DeviceEvent] = []
    @Published private(set) var state: ConnectionState = .idle

    private var session: URLSession?
    private var request: URLRequest?
    private var retryTask: Task<Void, Never>?
    private var attempt = 0
    private var stopped = true
    private var lastSeq = 0

    // Touched only on parseQueue (the delegate queue).
    private var lineBuffer = Data()
    private var dataLines: [String] = []

    private static let maxEvents = 400
    private static let maxRetryDelay: TimeInterval = 15

    private let parseQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "visionary.sse.parse"
        return q
    }()

    deinit {
        session?.invalidateAndCancel()
    }

    // MARK: - Lifecycle (call from the main queue)

    func start(request: URLRequest) {
        retryTask?.cancel()
        retryTask = nil
        stopSession()
        stopped = false
        attempt = 0
        self.request = request
        connect()
    }

    func stop() {
        stopped = true
        retryTask?.cancel()
        retryTask = nil
        stopSession()
        state = .idle
    }

    private func connect() {
        guard let request = request, !stopped else { return }
        state = .connecting
        let config = URLSessionConfiguration.default
        // Max gap between chunks: a quiet-but-alive stream may pause for long
        // stretches, and a 2-minute stall just falls through to a reconnect.
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 86_400
        let session = URLSession(configuration: config, delegate: self, delegateQueue: parseQueue)
        self.session = session
        session.dataTask(with: request).resume()
    }

    private func stopSession() {
        // invalidate breaks the session's strong hold on its delegate (self)
        session?.invalidateAndCancel()
        session = nil
        parseQueue.addOperation { [weak self] in
            self?.lineBuffer.removeAll()
            self?.dataLines.removeAll()
        }
    }

    /// Runs on the main queue; no-ops once stopped.
    private func scheduleRetry() {
        guard !stopped else { return }
        stopSession()
        state = .waitingToRetry
        let delay = min(Self.maxRetryDelay, pow(2, Double(attempt)))
        attempt += 1
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self = self, !Task.isCancelled, !self.stopped else { return }
            self.connect()
        }
    }

    // MARK: - URLSessionDataDelegate (runs on parseQueue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse).map { $0.statusCode == 200 } ?? true
        if ok {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, session === self.session, !self.stopped else { return }
                self.attempt = 0
                self.state = .open
            }
        }
        // .cancel routes non-200 through didCompleteWithError -> backoff retry
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<newline)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            handleLine(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lineBuffer.removeAll()
        dataLines.removeAll()
        DispatchQueue.main.async { [weak self] in
            // a superseded session's teardown must not retry over the live one
            guard let self = self, session === self.session else { return }
            self.scheduleRetry()
        }
    }

    // MARK: - SSE line protocol

    private func handleLine(_ line: String) {
        if line.isEmpty {
            dispatchPending()
            return
        }
        if line.hasPrefix(":") { return }               // keepalive comment
        guard line.hasPrefix("data:") else { return }   // ignore event:/id:/retry:
        var payload = String(line.dropFirst(5))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        dataLines.append(payload)
    }

    private func dispatchPending() {
        guard !dataLines.isEmpty else { return }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll()
        guard var event = try? APIClient.decoder.decode(DeviceEvent.self,
                                                        from: Data(payload.utf8)) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.stopped else { return }
            // keep seq unique + strictly increasing even if the device restarts
            self.lastSeq = event.seq > self.lastSeq ? event.seq : self.lastSeq + 1
            event.seq = self.lastSeq
            self.events.append(event)
            if self.events.count > Self.maxEvents {
                self.events.removeFirst(self.events.count - Self.maxEvents)
            }
        }
    }
}
