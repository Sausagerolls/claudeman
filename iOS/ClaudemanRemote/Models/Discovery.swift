import ClaudemanKit
import Foundation
import Network

/// A Claudeman Mac advertising itself over Bonjour on the local network.
struct DiscoveredMac: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint

    var id: String { name }
}

/// Browses for `_claudeman._tcp` services and resolves them to an IPv4 host and port.
@MainActor
final class Discovery: ObservableObject {
    @Published private(set) var macs: [DiscoveredMac] = []
    @Published private(set) var problem: String?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: RemoteAPI.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            let found = results.compactMap { result -> DiscoveredMac? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredMac(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in
                self.macs = Array(Set(found)).sorted { $0.name < $1.name }
            }
        }
        browser.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .failed(let error), .waiting(let error):
                    self.problem = "Can't search the local network (\(error.localizedDescription)). Check Settings › Privacy & Security › Local Network."
                default:
                    self.problem = nil
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Connects briefly to the service to learn its address, then disconnects.
    static func resolve(_ mac: DiscoveredMac) async -> (host: String, port: UInt16)? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: mac.endpoint, using: parameters)

        return await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var resolved: (String, UInt16)?
                    if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
                        var text = "\(host)"
                        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                        resolved = (text, port.rawValue)
                    }
                    connection.cancel()
                    if resumed.claim() { continuation.resume(returning: resolved) }
                case .failed, .cancelled:
                    if resumed.claim() { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                connection.cancel()
                if resumed.claim() { continuation.resume(returning: nil) }
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
