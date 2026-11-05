import ClaudemanKit
import Foundation
import Security

/// A Mac this device has paired with. The bearer token lives in the Keychain, keyed by `id`.
struct PairedMac: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16
    /// Other addresses this Mac has reported (local network, Tailscale), tried when `host` stops answering.
    var knownHosts: [String]?
    /// The Mac's stable id, checked before trusting a new address with our token.
    var serverID: String?

    var baseURL: URL? {
        // Bracket IPv6 literals so they form a valid URL authority.
        let authority = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(authority):\(port)")
    }

    var address: String { "\(host):\(port)" }
}

enum Keychain {
    private static let service = "com.sausagerolls.claudeman.remote.token"

    static func token(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, for id: UUID) {
        deleteToken(for: id)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func deleteToken(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class MacStore: ObservableObject {
    @Published private(set) var macs: [PairedMac] = [] {
        didSet { save() }
    }

    private let key = "pairedMacs"
    private var reconnecting: Set<UUID> = []
    private var lastReconnect: [UUID: Date] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([PairedMac].self, from: data) {
            macs = decoded
        }
        #if DEBUG
        seedFromLaunchArguments()
        #endif
    }

    #if DEBUG
    /// Development aid: `-seedMac <name> <host> <port> <token> [other,hosts]` pre-pairs a Mac (debug builds only).
    private func seedFromLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-seedMac"), args.count > index + 4,
              let port = UInt16(args[index + 3]) else { return }
        var mac = PairedMac(name: args[index + 1], host: args[index + 2], port: port)
        if args.count > index + 5, !args[index + 5].hasPrefix("-") {
            mac.knownHosts = args[index + 5].split(separator: ",").map(String.init)
        }
        if !macs.contains(where: { $0.address == mac.address }) { add(mac, token: args[index + 4]) }
    }
    #endif

    func add(_ mac: PairedMac, token: String) {
        Keychain.setToken(token, for: mac.id)
        macs.append(mac)
    }

    func update(_ mac: PairedMac) {
        guard let index = macs.firstIndex(where: { $0.id == mac.id }) else { return }
        macs[index] = mac
    }

    func remove(_ mac: PairedMac) {
        Keychain.deleteToken(for: mac.id)
        macs.removeAll { $0.id == mac.id }
    }

    func client(for mac: PairedMac) -> RemoteClient? {
        // Views can hold an older copy; a reconnect may have moved the Mac to a new address.
        let current = macs.first { $0.id == mac.id } ?? mac
        guard let url = current.baseURL else { return nil }
        return RemoteClient(baseURL: url, token: Keychain.token(for: mac.id))
    }

    /// Remembers what a paired Mac says about itself, for finding it again later.
    func learn(_ server: ServerInfo, about mac: PairedMac) {
        guard var current = macs.first(where: { $0.id == mac.id }) else { return }
        let before = current
        if let id = server.id { current.serverID = id }
        if let addresses = server.addresses, !addresses.isEmpty { current.knownHosts = addresses }
        if let port = server.port { current.port = port }
        current.name = server.name
        if current != before { update(current) }
    }

    /// Looks for the Mac at every address we know of, plus on the local network, and switches to
    /// the first one that accepts our token. Returns true if a working address was found.
    @discardableResult
    func reconnect(_ mac: PairedMac) async -> Bool {
        guard let current = macs.first(where: { $0.id == mac.id }), !reconnecting.contains(mac.id),
              Date().timeIntervalSince(lastReconnect[mac.id] ?? .distantPast) > 5,
              let token = Keychain.token(for: mac.id) else { return false }
        reconnecting.insert(mac.id)
        lastReconnect[mac.id] = Date()
        defer { reconnecting.remove(mac.id) }

        var candidates = (current.knownHosts ?? []).map { ($0, current.port) }
        if let found = await Discovery.find(named: current.name) { candidates.append(found) }
        candidates = candidates.filter { $0.0 != current.host || $0.1 != current.port }

        let serverID = current.serverID
        let name = current.name
        let winner: (host: String, port: UInt16, server: ServerInfo)? = await withTaskGroup(
            of: (host: String, port: UInt16, server: ServerInfo)?.self
        ) { group in
            for (host, port) in candidates {
                group.addTask {
                    let address = PairedMac(name: "", host: host, port: port)
                    guard let url = address.baseURL else { return nil }
                    // An address can belong to something else on another network, so check who
                    // answers before sending our token there.
                    guard let info = try? await RemoteClient(baseURL: url, token: nil).info(timeout: 3),
                          serverID != nil ? info.id == serverID : info.name == name,
                          let status = try? await RemoteClient(baseURL: url, token: token).status() else { return nil }
                    return (host, port, status.server)
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }

        guard let winner, var latest = macs.first(where: { $0.id == mac.id }) else { return false }
        latest.host = winner.host
        latest.port = winner.port
        update(latest)
        learn(winner.server, about: latest)
        return true
    }

    private func save() {
        if let data = try? JSONEncoder().encode(macs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
