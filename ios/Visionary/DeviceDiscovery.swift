import Foundation
import Network

struct DiscoveredDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
}

final class DeviceDiscovery: ObservableObject {
    @Published var devices: [DiscoveredDevice] = []

    private var browser: NWBrowser?

    func start() {
        stop()
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_visionary._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results
                .compactMap(DiscoveredDevice.init(result:))
                .sorted { $0.name < $1.name }
            DispatchQueue.main.async { self?.devices = found }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                DispatchQueue.main.async { self?.devices = [] }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        devices = []
    }
}

private extension DiscoveredDevice {
    init?(result: NWBrowser.Result) {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        // avahi advertises the service under the Pi's hostname, so <name>.local
        // resolves via mDNS without an extra endpoint-resolution round trip
        let host = name.lowercased().replacingOccurrences(of: " ", with: "-")
        guard let url = URL(string: "http://\(host).local:8321") else { return nil }
        self.init(id: name, name: name, url: url)
    }
}
