import Foundation

/// Everything a phone needs to pair, encoded as a `claudeman://pair?...` URL.
/// The Mac shows it as a QR code; the iOS app (or the Camera app, via the URL scheme) reads it.
public struct PairingLink: Hashable, Sendable {
    public static let scheme = "claudeman"

    public var name: String
    /// Addresses to try, most preferred first (e.g. Wi-Fi, then Tailscale).
    public var hosts: [String]
    public var port: UInt16
    public var code: String

    public init(name: String, hosts: [String], port: UInt16, code: String) {
        self.name = name
        self.hosts = hosts
        self.port = port
        self.code = code
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "hosts", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "code", value: code),
        ]
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        let hosts = (value("hosts") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !hosts.isEmpty,
              let port = value("port").flatMap(UInt16.init),
              let code = value("code"), code.count == 6, code.allSatisfy(\.isNumber) else { return nil }
        self.init(name: value("name") ?? hosts[0], hosts: hosts, port: port, code: code)
    }
}
