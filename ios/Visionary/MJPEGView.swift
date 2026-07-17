import SwiftUI
import UIKit

/// Parses a multipart/x-mixed-replace MJPEG body by scanning for JPEG
/// SOI/EOI markers (FFD8/FFD9) and publishes each complete frame.
final class MJPEGStream: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var image: UIImage?
    @Published var isStreaming = false

    private var session: URLSession?
    private var buffer = Data()
    private let parseQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "visionary.mjpeg.parse"
        return q
    }()

    private static let soi = Data([0xFF, 0xD8])
    private static let eoi = Data([0xFF, 0xD9])
    private static let maxBuffer = 2 * 1024 * 1024

    func start(request: URLRequest) {
        stop()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15       // max gap between chunks
        config.timeoutIntervalForResource = 86_400
        let session = URLSession(configuration: config, delegate: self, delegateQueue: parseQueue)
        self.session = session
        isStreaming = true
        session.dataTask(with: request).resume()
    }

    func stop() {
        // invalidate breaks the session's strong hold on its delegate (self)
        session?.invalidateAndCancel()
        session = nil
        parseQueue.addOperation { [weak self] in self?.buffer.removeAll() }
        isStreaming = false
    }

    // MARK: - URLSessionDataDelegate (runs on parseQueue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let frame = nextFrame() {
            if let img = UIImage(data: frame) {
                DispatchQueue.main.async { [weak self] in self?.image = img }
            }
        }
        if buffer.count > Self.maxBuffer {
            buffer.removeAll(keepingCapacity: true)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async { [weak self] in self?.isStreaming = false }
    }

    private func nextFrame() -> Data? {
        guard let soiRange = buffer.range(of: Self.soi) else {
            // no frame start yet: drop the multipart chatter but keep the last
            // byte in case an SOI marker is split across chunks
            if buffer.count > 1 {
                buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.endIndex, offsetBy: -1))
            }
            return nil
        }
        if soiRange.lowerBound > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<soiRange.lowerBound)
        }
        let searchStart = buffer.index(buffer.startIndex, offsetBy: 2)
        guard searchStart < buffer.endIndex,
              let eoiRange = buffer.range(of: Self.eoi, in: searchStart..<buffer.endIndex) else {
            return nil
        }
        let frame = buffer.subdata(in: buffer.startIndex..<eoiRange.upperBound)
        buffer.removeSubrange(buffer.startIndex..<eoiRange.upperBound)
        return frame
    }
}

struct MJPEGView: View {
    let request: URLRequest
    @StateObject private var stream = MJPEGStream()

    var body: some View {
        ZStack {
            Color.black
            if let image = stream.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if stream.isStreaming {
                ProgressView()
                    .tint(.white)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.largeTitle)
                    Text("Stream unavailable")
                }
                .foregroundColor(.white)
            }
        }
        .onAppear { stream.start(request: request) }
        .onDisappear { stream.stop() }
        .accessibilityLabel("Live camera preview from the glasses")
    }
}
